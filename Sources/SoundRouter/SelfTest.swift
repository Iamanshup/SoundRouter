import AppKit
import SwiftUI
import CoreAudio
import Foundation

/// `SoundRouter --selftest <log path>`: exercises device enumeration, volume control and
/// the real tap → aggregate → speaker pipeline against an `afplay` process.
enum SelfTest {
    static var log = ""
    static func say(_ s: String) { log += s + "\n"; print(s) }

    static func run() -> Never {
        let args = CommandLine.arguments
        let logPath = args.firstIndex(of: "--selftest").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        var failures = 0
        func expect(_ ok: Bool, _ what: String) {
            say((ok ? "PASS " : "FAIL ") + what)
            if !ok { failures += 1 }
        }

        let devices = DeviceManager.outputDevices(softwareVolumes: [:])
        say("Output devices:")
        for d in devices {
            say("  - \(d.name) uid=\(d.uid) default=\(d.isDefault) hwVolume=\(d.hasHardwareVolume) volume=\(d.volume)")
        }
        expect(!devices.isEmpty, "found output devices")
        // Prefer a speaker that is NOT the system output: that's the interesting case.
        let wanted = ProcessInfo.processInfo.environment["SR_DEVICE"]
        guard let target = devices.first(where: { wanted != nil && $0.name.contains(wanted!) })
                ?? devices.first(where: { !$0.isDefault }) ?? devices.first else { finish(1, logPath) }
        say("Routing target: \(target.name) (system output is \(devices.first(where: \.isDefault)?.name ?? "?"))")

        // Volume round-trip.
        if target.hasHardwareVolume {
            let original = target.volume
            let probe: Float = original > 0.5 ? 0.3 : 0.6
            DeviceManager.setHardwareVolume(target.id, probe)
            let readBack = DeviceManager.hardwareVolume(target.id, DeviceManager.volumeElements(target.id))
            expect(abs(readBack - probe) < 0.05, "set device volume to \(probe), read back \(readBack)")
            DeviceManager.setHardwareVolume(target.id, original)
        }

        // Play a known sound with afplay.
        let tmp = NSTemporaryDirectory() + "soundrouter-selftest.aiff"
        let sayTask = Process()
        sayTask.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        sayTask.arguments = ["-o", tmp, String(repeating: "Sound router test. ", count: 14)]
        try? sayTask.run(); sayTask.waitUntilExit()
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = ["-v", "0.4", tmp]
        do { try player.run() } catch { expect(false, "launch afplay: \(error)"); finish(1, logPath) }
        defer { player.terminate() }

        // afplay is our child, so app grouping (which hides SoundRouter's own processes)
        // would skip it; look its process object up directly instead.
        var object: AudioObjectID = 0
        var playing = false
        for _ in 0..<40 {
            var pid = player.processIdentifier
            var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            AudioObjectGetPropertyData(systemObject, &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
            playing = object != 0 && (CA.get(object, address(kAudioProcessPropertyIsRunningOutput), UInt32(0)) ?? 0) != 0
            if playing { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        expect(object != 0, "afplay has an audio process object (\(object))")
        expect(playing, "afplay reported as playing")
        say("Apps known to the audio server (grouped):")
        for a in ProcessManager.audioApps() {
            say("  - \(a.name) [\(a.id)] processes=\(a.processObjects.count) playing=\(a.isPlaying) regular=\(a.isRegularApp)")
        }
        guard object != 0 else { finish(1, logPath) }
        let app = AudioApp(id: "afplay", name: "afplay", pid: player.processIdentifier,
                           processObjects: [object], isPlaying: playing, isRegularApp: false)

        do {
            let router = try TapRouter(name: app.name, processObjects: app.processObjects.sorted(),
                                       deviceUID: target.uid, gain: 1)
            var maxPeak: Float = 0
            for _ in 0..<30 { Thread.sleep(forTimeInterval: 0.1); maxPeak = max(maxPeak, router.state.peak) }
            say("  gain 1.0: callbacks=\(router.state.callbacks) maxPeak=\(maxPeak)")
            expect(router.state.callbacks > 50, "IO proc running on \(target.name)")
            expect(maxPeak > 0.01, "tapped audio reaches the output buffers")

            // Sample-rate switch mid-stream (what Bluetooth headphones do when their mic opens).
            let rateAddr = address(kAudioDevicePropertyNominalSampleRate)
            let rates = CA.array(target.id, address(kAudioDevicePropertyAvailableNominalSampleRates), AudioValueRange())
            let originalRate = CA.get(target.id, rateAddr, Float64(0)) ?? 0
            if let other = rates.map(\.mMinimum).first(where: { $0 != originalRate && ($0 == 44100 || $0 == 48000) }) {
                let shortBefore = router.state.shortCallbacks
                _ = CA.set(target.id, rateAddr, other)
                Thread.sleep(forTimeInterval: 1.0)   // let the device settle
                let cb1 = router.state.callbacks, short1 = router.state.shortCallbacks
                var peakAfter: Float = 0
                for _ in 0..<20 { Thread.sleep(forTimeInterval: 0.1); peakAfter = max(peakAfter, router.state.peak) }
                let cb2 = router.state.callbacks, short2 = router.state.shortCallbacks
                let nowRate = CA.get(target.id, rateAddr, Float64(0)) ?? 0
                say("  rate \(Int(originalRate)) → \(Int(nowRate)): callbacks +\(cb2 - cb1), gaps during switch \(short1 - shortBefore), gaps after +\(short2 - short1), peak \(peakAfter)")
                expect(cb2 > cb1 + 20 && peakAfter > 0.01, "app routing keeps playing after the speaker's sample rate changes")
                expect(short2 == short1, "no gaps at the new sample rate")
                _ = CA.set(target.id, rateAddr, originalRate)
                Thread.sleep(forTimeInterval: 1.0)
                let cb3 = router.state.callbacks, short3 = router.state.shortCallbacks
                var peakBack: Float = 0
                for _ in 0..<20 { Thread.sleep(forTimeInterval: 0.1); peakBack = max(peakBack, router.state.peak) }
                say("  back to \(Int(CA.get(target.id, rateAddr, Float64(0)) ?? 0)): callbacks +\(router.state.callbacks - cb3), gaps +\(router.state.shortCallbacks - short3), peak \(peakBack), afplay running=\(player.isRunning)")
                expect(peakBack > 0.01 && router.state.shortCallbacks == short3, "still playing cleanly after switching back")
            } else {
                say("  (skipping sample-rate switch: \(target.name) has no alternative rate)")
            }

            router.state.gain = 0.5
            var halfPeak: Float = 0
            for _ in 0..<20 { Thread.sleep(forTimeInterval: 0.1); halfPeak = max(halfPeak, router.state.peak) }
            say("  gain 0.5: maxPeak=\(halfPeak)")
            expect(halfPeak > 0 && halfPeak < maxPeak, "per-app volume scales output")

            router.state.gain = 0
            Thread.sleep(forTimeInterval: 0.2)
            var zeroPeak: Float = 0
            for _ in 0..<10 { Thread.sleep(forTimeInterval: 0.1); zeroPeak = max(zeroPeak, router.state.peak) }
            expect(zeroPeak == 0, "per-app mute gives silence (peak \(zeroPeak))")
            router.stop()
        } catch {
            expect(false, "route afplay → \(target.name): \(error)")
        }

        say(failures == 0 ? "ALL PASSED" : "\(failures) FAILURE(S)")
        finish(failures == 0 ? 0 : 1, logPath)
    }

    static func finish(_ code: Int32, _ path: String?) -> Never {
        if let path { try? log.write(toFile: path, atomically: true, encoding: .utf8) }
        exit(code)
    }
}

/// `SoundRouter --snapshot <dir>`: renders the main window and the menu bar panel with live data.
enum Snapshot {
    @MainActor static func run(_ dir: String) -> Never {
        _ = NSApplication.shared
        let model = AudioModel.shared
        if ProcessInfo.processInfo.environment["SR_LONG"] != nil { model.showBackgroundProcesses = true }
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        let views: [(String, AnyView, NSSize)] = [
            ("main.png", AnyView(MainView().environmentObject(model).environmentObject(UIState.shared)), NSSize(width: 860, height: 620)),
            ("menubar.png", AnyView(MenuBarView().environmentObject(model).environmentObject(UIState.shared)), NSSize(width: 440, height: 0)),
        ]
        for (name, view, size) in views {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size.height > 0 ? size : NSHostingView(rootView: view).fittingSize), styleMask: [.titled], backing: .buffered, defer: false)
            let host = NSHostingView(rootView: view)
            print("\(name) natural size: \(host.fittingSize)")
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = host
            window.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/" + name))
            window.close()
        }
        exit(0)
    }
}

/// `SoundRouter --menutest <dir>`: opens the real menu bar popover and main window and saves
/// them in light and dark appearance (menubar-light.png, main-dark.png, ...).
enum MenuTest {
    @MainActor static func run(_ dir: String, statusBar: StatusBarController, mainWindow: NSWindow?) {
        if ProcessInfo.processInfo.environment["SR_LONG"] != nil { AudioModel.shared.showBackgroundProcesses = true }
        if let expand = ProcessInfo.processInfo.environment["SR_EXPAND"] { UIState.shared.expanded.insert(expand) }
        if let section = ProcessInfo.processInfo.environment["SR_SECTION"] { UIState.shared.section = SidebarSection(rawValue: section) }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            statusBar.toggle()
            try? await Task.sleep(for: .seconds(1))
            guard statusBar.popover.isShown, let view = statusBar.popover.contentViewController?.view else {
                print("MENUTEST popover did not open"); exit(1)
            }
            print("MENUTEST popover size: \(view.bounds.size)")
            let main = mainWindow
            for (name, appearance, bg) in [("light", NSAppearance.Name.aqua, NSColor(white: 0.93, alpha: 1)),
                                           ("dark", NSAppearance.Name.darkAqua, NSColor(white: 0.17, alpha: 1))] {
                NSApp.appearance = NSAppearance(named: appearance)
                statusBar.popover.appearance = NSAppearance(named: appearance)
                view.window?.appearance = NSAppearance(named: appearance)
                main?.appearance = NSAppearance(named: appearance)
                try? await Task.sleep(for: .seconds(0.8))
                save(view, background: bg, to: "\(dir)/menubar-\(name).png")
                if let frame = main?.contentView?.superview {
                    save(frame, background: appearance == .aqua ? .white : NSColor(white: 0.12, alpha: 1), to: "\(dir)/main-\(name).png")
                }
            }
            if ProcessInfo.processInfo.environment["SR_LONG"] != nil { AudioModel.shared.showBackgroundProcesses = false }
            exit(0)
        }
    }

    /// Popover/window backgrounds are translucent materials that don't render offscreen,
    /// so composite over a representative colour.
    @MainActor private static func save(_ view: NSView, background: NSColor, to path: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let out = NSImage(size: view.bounds.size)
        out.lockFocus()
        background.setFill()
        NSRect(origin: .zero, size: view.bounds.size).fill()
        rep.draw(in: NSRect(origin: .zero, size: view.bounds.size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        out.unlockFocus()
        guard let tiff = out.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return }
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

/// `SR_SIMULATE_BT_HEADSET=<mic name> SoundRouter --mictest <log>`: microphones and the
/// "keep headphones in high quality" guard, using the named mic as a stand-in headset.
enum MicTest {
    @MainActor static func run(_ logPath: String) async {
        var log = ""
        var failures = 0
        func say(_ s: String) { log += s + "\n"; print(s) }
        func expect(_ ok: Bool, _ what: String) { say((ok ? "PASS " : "FAIL ") + what); if !ok { failures += 1 } }
        func finish() -> Never {
            say(failures == 0 ? "ALL PASSED" : "\(failures) FAILURE(S)")
            try? log.write(toFile: logPath, atomically: true, encoding: .utf8)
            exit(failures == 0 ? 0 : 1)
        }
        // Must suspend (not spin a nested run loop) so Core Audio's main-queue notifications get delivered.
        func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

        // 1. Guard decision logic.
        func mic(_ name: String, _ transport: UInt32, headset: Bool, isDefault: Bool) -> InputDevice {
            InputDevice(id: AudioObjectID(name.hashValue & 0xffff), uid: name, name: name, transport: transport, isDefault: isDefault,
                        hasVolume: true, volume: 1, canMute: true, muted: false, isBluetoothHeadset: headset)
        }
        let bt = kAudioDeviceTransportTypeBluetooth, builtIn = kAudioDeviceTransportTypeBuiltIn, usb = kAudioDeviceTransportTypeUSB
        expect(InputManager.headsetGuardTarget([mic("AirPods", bt, headset: true, isDefault: true), mic("USB mic", usb, headset: false, isDefault: false),
                                                mic("MacBook mic", builtIn, headset: false, isDefault: false)])?.name == "MacBook mic",
               "headset as system mic → switch to the built-in mic (preferred over other mics)")
        expect(InputManager.headsetGuardTarget([mic("AirPods", bt, headset: true, isDefault: false),
                                                mic("MacBook mic", builtIn, headset: false, isDefault: true)]) == nil,
               "built-in mic already in use → leave it alone")
        expect(InputManager.headsetGuardTarget([mic("AirPods", bt, headset: true, isDefault: true), mic("USB mic", usb, headset: false, isDefault: false)])?.name == "USB mic",
               "no built-in mic (e.g. Mac mini) → use another non-headset mic")
        expect(InputManager.headsetGuardTarget([mic("AirPods", bt, headset: true, isDefault: true), mic("XM5", bt, headset: true, isDefault: false)]) == nil,
               "only headset mics available → leave it alone")

        // 2. Real devices.
        let model = AudioModel.shared
        let originalDefault = InputManager.defaultInputID()
        let originalGuard = model.keepHeadphonesHighQuality
        let inputs = InputManager.inputDevices()
        say("Microphones:")
        for i in inputs { say("  - \(i.name) default=\(i.isDefault) volume=\(i.hasVolume ? "\(i.volume)" : "n/a") mute=\(i.canMute) headset=\(i.isBluetoothHeadset)") }
        guard let builtInMic = inputs.first(where: \.isBuiltIn) else { expect(false, "built-in mic found"); finish() }
        expect(true, "built-in mic found (\(builtInMic.name))")
        expect(inputs.contains { $0.isDefault }, "system mic is identified")

        // 3. Input level round trip.
        if builtInMic.hasVolume {
            let original = builtInMic.volume
            let probe: Float = original > 0.5 ? 0.35 : 0.65
            model.setVolume(probe, for: builtInMic)
            let readBack = DeviceManager.hardwareVolume(builtInMic.id, DeviceManager.volumeElements(builtInMic.id, scope: kAudioObjectPropertyScopeInput), scope: kAudioObjectPropertyScopeInput)
            expect(abs(readBack - probe) < 0.05, "set \(builtInMic.name) input level to \(probe), read back \(readBack)")
            DeviceManager.setHardwareVolume(builtInMic.id, original, scope: kAudioObjectPropertyScopeInput)
        }

        // 4. Live guard, with a stand-in headset.
        guard let fake = inputs.first(where: \.isBluetoothHeadset), !fake.isBuiltIn else {
            say("(no stand-in headset: set SR_SIMULATE_BT_HEADSET to a mic name)")
            finish()
        }
        if InputManager.defaultInputID() != builtInMic.id { InputManager.setDefaultInput(builtInMic.id); await wait(0.5) }
        model.keepHeadphonesHighQuality = true
        await wait(0.5)
        InputManager.setDefaultInput(fake.id)          // what macOS does when headphones connect
        await wait(1.5)
        expect(InputManager.defaultInputID() == builtInMic.id, "guard on: when the system mic becomes \(fake.name), it is switched back to \(builtInMic.name)")
        expect(model.micNotice?.contains(fake.name) == true, "a notice explains the switch: \(model.micNotice ?? "-")")

        // 5. Choosing the headset mic in SoundRouter is respected.
        model.makeDefault(model.inputs.first { $0.id == fake.id }!)
        await wait(1.5)
        expect(InputManager.defaultInputID() == fake.id, "explicitly choosing \(fake.name) in SoundRouter sticks")
        expect(!model.keepHeadphonesHighQuality, "…and turns the setting off, with notice: \(model.micNotice ?? "-")")

        // 6. Guard off: no interference.
        InputManager.setDefaultInput(builtInMic.id); await wait(0.5)
        InputManager.setDefaultInput(fake.id); await wait(1.5)
        expect(InputManager.defaultInputID() == fake.id, "guard off: SoundRouter leaves the system mic alone")

        // Restore.
        if let originalDefault { InputManager.setDefaultInput(originalDefault) }
        model.keepHeadphonesHighQuality = originalGuard
        await wait(0.5)
        say("restored system mic to \(InputManager.inputDevices().first(where: \.isDefault)?.name ?? "?"), setting=\(model.keepHeadphonesHighQuality)")
        finish()
    }
}

/// `SoundRouter --docktest <log>`: close the window → no Dock icon but still running with
/// a menu bar item; "Open SoundRouter…" → window and Dock icon back. Each phase is held for
/// 3 s (with a marker file) so an outside script can confirm the Dock state with lsappinfo.
enum DockTest {
    @MainActor static func run(_ logPath: String, delegate: AppDelegate) async {
        var log = ""
        var failures = 0
        func say(_ s: String) { log += s + "\n"; print(s) }
        func expect(_ ok: Bool, _ what: String) { say((ok ? "PASS " : "FAIL ") + what); if !ok { failures += 1 } }
        func phase(_ name: String) async {
            try? name.write(toFile: logPath + ".phase", atomically: true, encoding: .utf8)
            try? await Task.sleep(for: .seconds(3))
        }
        try? await Task.sleep(for: .seconds(1))
        expect(NSApp.activationPolicy() == .regular && delegate.mainWindow?.isVisible == true, "at launch: window open and app in the Dock")
        await phase("open")

        delegate.mainWindow?.performClose(nil)
        try? await Task.sleep(for: .milliseconds(300))
        expect(delegate.mainWindow?.isVisible == false, "window closes")
        expect(NSApp.activationPolicy() == .accessory, "closing the window removes the Dock icon")
        expect(delegate.statusBar?.item.isVisible == true, "menu bar item is still there")
        delegate.statusBar?.toggle()
        try? await Task.sleep(for: .milliseconds(500))
        expect(delegate.statusBar?.popover.isShown == true, "menu bar panel still opens while hidden from the Dock")
        await phase("closed")

        // What the menu bar's "Open SoundRouter…" button does.
        delegate.statusBar?.popover.performClose(nil)
        delegate.showMainWindow()
        try? await Task.sleep(for: .milliseconds(300))
        expect(delegate.mainWindow?.isVisible == true && NSApp.activationPolicy() == .regular, "“Open SoundRouter…” brings back the window and Dock icon")
        await phase("reopened")

        delegate.mainWindow?.performClose(nil)
        try? await Task.sleep(for: .milliseconds(300))
        expect(NSApp.activationPolicy() == .accessory, "closing again hides it from the Dock again")
        await phase("closed-again")

        say(failures == 0 ? "ALL PASSED" : "\(failures) FAILURE(S)")
        try? log.write(toFile: logPath, atomically: true, encoding: .utf8)
        exit(failures == 0 ? 0 : 1)
    }
}
