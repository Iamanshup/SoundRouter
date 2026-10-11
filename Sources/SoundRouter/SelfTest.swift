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
        let demo = ProcessInfo.processInfo.environment["SR_DEMO"] != nil
        let model = AudioModel.shared
        let before = (model.presets.map(\.id), model.automations.map(\.id))
        if demo {
            model.savePreset(named: "Work")
            model.savePreset(named: "Movie night")
            if let uid = model.devices.first?.uid {
                model.addAutomation(Automation(deviceUID: uid, deviceName: model.deviceName(uid), onConnect: true,
                                               makeDefault: true, presetID: model.presets.last?.id))
            }
            if let uid = model.devices.first?.uid { UIState.shared.expanded.insert("spk:" + uid) }
        }
        func cleanUp() {
            guard demo else { return }
            for p in model.presets where !before.0.contains(p.id) { model.deletePreset(p.id) }
            for a in model.automations where !before.1.contains(a.id) { model.deleteAutomation(a.id) }
        }
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
            cleanUp()
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

/// `SoundRouter --featuretest <log>`: alerts speaker, multiple speakers, boost, balance, delay,
/// presets, automations and shortcuts. Creates a temporary virtual speaker (a multi-output device
/// on the built-in speakers) so there is a second speaker to work with, and removes it afterwards.
enum FeatureTest {
    static let testUID = "com.soundrouter.test-speaker"

    @MainActor static func run(_ logPath: String) async {
        var log = ""
        var failures = 0
        func say(_ s: String) { log += s + "\n"; print(s) }
        func expect(_ ok: Bool, _ what: String) { say((ok ? "PASS " : "FAIL ") + what); if !ok { failures += 1 } }
        func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
        let model = AudioModel.shared

        // ---- DSP units
        expect(DSP.softLimit(0.5) == 0.5 && DSP.softLimit(-0.7) == -0.7, "limiter leaves normal levels untouched")
        let limited = DSP.softLimit(1.6)
        expect(limited > 0.95 && limited < 1.0 && DSP.softLimit(-1.6) == -limited, "limiter keeps boosted peaks below full scale (1.6 → \(limited))")
        let (l, r) = DSP.channelGains(gain: 1, balance: -1)
        let (l2, r2) = DSP.channelGains(gain: 2, balance: 0.5)
        expect(l == 1 && r == 0 && l2 == 1 && r2 == 2, "balance: full left mutes right; half right halves left")
        let line = DelayLine(maxFrames: 100)
        let buf = UnsafeMutablePointer<Float>.allocate(capacity: 64 * 2)
        buf.initialize(repeating: 0, count: 128); buf[0] = 1; buf[1] = 1
        line.process(buf, frames: 64, delay: 10)
        expect(buf[20] == 1 && buf[0] == 0, "delay line shifts audio by the requested frames")
        buf.deallocate()

        // ---- Snapshot what we touch, to restore it.
        let originalDefault = DeviceManager.defaultOutputID()
        let originalSystem = DeviceManager.systemOutputID()
        let originalAlerts = model.alertsSetting
        let originalRules = model.rules
        let originalPresets = model.presets.map(\.id)
        let originalAutomations = model.automations.map(\.id)
        guard let builtIn = model.devices.first(where: { $0.transport == kAudioDeviceTransportTypeBuiltIn }) else {
            expect(false, "built-in speakers found"); finish(); return
        }

        // ---- Presets + automations, before the test speaker exists.
        model.setRule(AppRule(deviceUID: builtIn.uid, volume: 0.5, name: "Preset probe"), forAppID: "test.preset.a")
        model.savePreset(named: "Test Connect")
        let presetA = model.presets.last!.id
        model.setRule(nil, forAppID: "test.preset.a")
        model.setRule(AppRule(volume: 0.25, name: "Preset probe"), forAppID: "test.preset.b")
        model.savePreset(named: "Test Disconnect")
        let presetB = model.presets.last!.id
        expect(model.activePresetID == presetB, "the matching preset shows as active")
        model.addAutomation(Automation(deviceUID: testUID, deviceName: "SoundRouter Test Speaker", onConnect: true, makeDefault: true, presetID: presetA))
        model.addAutomation(Automation(deviceUID: testUID, deviceName: "SoundRouter Test Speaker", onConnect: false, makeDefault: false, presetID: presetB))

        // ---- "Connect" a second speaker.
        var testDevice = AudioObjectID(0)
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SoundRouter Test Speaker",
            kAudioAggregateDeviceUIDKey: testUID,
            kAudioAggregateDeviceIsStackedKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: builtIn.uid]],
            kAudioAggregateDeviceMainSubDeviceKey: builtIn.uid,
        ]
        let status = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &testDevice)
        expect(status == noErr, "created a temporary test speaker")
        await wait(2.5)
        let test = model.device(testUID)
        expect(test != nil, "SoundRouter sees the new speaker")
        expect(model.defaultDevice?.uid == testUID, "automation on connect: made it the Mac default")
        expect(model.rules["test.preset.a"]?.volume == 0.5 && model.rules["test.preset.b"] == nil, "automation on connect: applied preset “Test Connect”")
        expect(HUD.lastMessage?.contains("connected") == true, "automation shows a notice: \(HUD.lastMessage ?? "-")")

        // ---- Alerts speaker.
        model.setAlertsDevice(builtIn.uid)
        await wait(0.5)
        expect(DeviceManager.systemOutputID() == builtIn.id, "alerts go to \(builtIn.name) while the Mac default is the test speaker")
        model.setAlertsDevice(nil)
        await wait(0.5)
        expect(DeviceManager.systemOutputID() == test?.id, "“Same as Mac default” sends alerts to the test speaker")

        // ---- Hotkeys.
        let registered = HotKeys.shared.registered.count
        expect(registered == 14 || !model.shortcutsEnabled, "\(registered) global shortcuts registered")
        let before = model.defaultDevice?.uid
        HotKeys.shared.trigger(1)
        await wait(0.5)
        expect(model.defaultDevice?.uid != before && HUD.lastMessage?.hasPrefix("Mac default:") == true,
               "⌃⌥⌘S switches the Mac default (\(HUD.lastMessage ?? "-"))")
        HotKeys.shared.trigger(11)   // preset 2
        await wait(0.3)
        expect(model.rules["test.preset.b"]?.volume == 0.25, "⌃⌥⌘2 applies preset 2")

        // ---- Real audio: multiple speakers, boost, balance, delay.
        model.setRule(nil, forAppID: "test.preset.b")
        let player = try? SpawnDisclaimed.run("/usr/bin/afplay", ["-v", "0.4", SelfTest.speechFile()])
        var app: AudioApp?
        for _ in 0..<40 {
            await wait(0.15)
            model.refresh()
            app = model.apps.first { a in a.processObjects.contains { CA.get($0, address(kAudioProcessPropertyPID), pid_t(0)) == player } }
            if app?.isPlaying == true { break }
        }
        expect(app != nil, "test player appears as an app (\(app?.name ?? "-"))")
        if let app {
            // The test speaker is a multi-output device: SoundRouter plays on the real speaker inside it.
            model.setRule(AppRule(deviceUID: testUID, name: app.name), forAppID: app.id)
            await wait(2)
            var basePeak: Float = 0
            for _ in 0..<15 { await wait(0.1); basePeak = max(basePeak, model.routerStats(app.id)[builtIn.uid]?.peak ?? 0) }
            say("  to the test speaker at 100%: routers \(model.routerStats(app.id).keys.map { model.deviceName($0) }), peak \(basePeak)")
            expect(model.routerStats(app.id).count == 1 && basePeak > 0.05,
                   "routing to a multi-output device plays on the real speaker inside it")

            // Two simultaneous captures of one app (what playing on several speakers uses).
            if let a = try? TapRouter(name: "diag-a", processObjects: app.processObjects.sorted(), deviceUID: builtIn.uid, gain: 0.0001),
               let b = try? TapRouter(name: "diag-b", processObjects: app.processObjects.sorted(), deviceUID: builtIn.uid, gain: 0.0001) {
                var pa: Float = 0, pb: Float = 0
                for _ in 0..<15 { await wait(0.1); pa = max(pa, a.state.peak); pb = max(pb, b.state.peak) }
                expect(pa > 0 && pb > 0 && a.state.shortCallbacks == 0 && b.state.shortCallbacks == 0,
                       "two simultaneous captures of one app both receive its audio (as for two speakers)")
                a.stop(); b.stop()
            }

            // Test speaker + built-in: the same physical speaker, so it must play once, not twice.
            model.setRule(AppRule(deviceUID: testUID, name: app.name, extraDeviceUIDs: [builtIn.uid]), forAppID: app.id)
            await wait(1)
            expect(model.routerStats(app.id).count == 1, "a speaker reachable two ways plays once (no doubled audio)")

            // Boost + balance.
            model.setRule(AppRule(deviceUID: testUID, volume: 1.5, name: app.name, balance: -1), forAppID: app.id)
            await wait(1)
            var left: Float = 0, right: Float = 0
            for _ in 0..<20 {
                await wait(0.1)
                if let st = model.routerStats(app.id)[builtIn.uid] { left = max(left, st.peakLeft); right = max(right, st.peakRight) }
            }
            say("  150%, balance full left: L \(left), R \(right)")
            expect(right == 0 && left > 0.05, "balance full left: right channel silent")
            expect(left > basePeak * 1.3 && left < 1, "150% boost is louder than 100% and stays below full scale (\(left) vs \(basePeak))")
            model.setRule(nil, forAppID: app.id)
            await wait(0.5)
            expect(model.routerStats(app.id).isEmpty, "removing the setting stops routing")
        }
        if let player { kill(player, SIGTERM) }
        model.setDelay(0, for: builtIn)

        // ---- Tab resampling: a 44.1 kHz browser stream on a 48 kHz speaker (as happens when a
        // tab plays on two speakers with different rates).
        func feed(_ player: TabPlayer, rate: Double, seconds: Double) async {
            let chunk = Int(rate / 100)
            var phase: Float = 0
            let step = 2 * Float.pi * 440 / Float(rate)
            var samples = [Float](repeating: 0, count: chunk * 2)
            let start = Date()
            var sent = 0
            while Date().timeIntervalSince(start) < seconds {
                let due = Int(Date().timeIntervalSince(start) * 100) + 1
                while sent < due {
                    for i in 0..<chunk { let v = 0.2 * sin(phase); phase += step; samples[2 * i] = v; samples[2 * i + 1] = v }
                    samples.withUnsafeBufferPointer { player.ring.write($0, channels: 2) }
                    sent += 1
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        let deviceRate = CA.get(builtIn.id, address(kAudioDevicePropertyNominalSampleRate), Float64(48000)) ?? 48000
        let streamRate: Double = deviceRate == 44100 ? 48000 : 44100
        if let tab = try? TabPlayer(device: builtIn, gain: 0.001) {
            tab.streamRate = streamRate
            await feed(tab, rate: streamRate, seconds: 1)          // settle
            let u0 = tab.underruns, s0 = tab.skips
            await feed(tab, rate: streamRate, seconds: 3)
            say("  tab stream \(Int(streamRate)) Hz on a \(Int(deviceRate)) Hz speaker: underruns +\(tab.underruns - u0), skips +\(tab.skips - s0), peak \(tab.state.peak / 0.001)")
            expect(tab.underruns == u0 && tab.skips == s0 && tab.state.peak > 0.0001,
                   "a tab stream at a different rate is resampled with no drift")
            // Control: without resampling the same stream drifts.
            tab.streamRate = deviceRate
            await feed(tab, rate: streamRate, seconds: 1)
            let u1 = tab.underruns, s1 = tab.skips
            await feed(tab, rate: streamRate, seconds: 3)
            expect(tab.underruns > u1 || tab.skips > s1, "control: without resampling it drifts (underruns +\(tab.underruns - u1), skips +\(tab.skips - s1))")
            tab.stop()
        }

        // ---- ⌃⌥⌘M: mute the app in front.
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid(), let id = front.bundleIdentifier {
            HotKeys.shared.trigger(2)
            await wait(0.3)
            let muted = model.rules[id]?.muted == true
            HotKeys.shared.trigger(2)
            await wait(0.3)
            expect(muted && model.rules[id] == nil, "⌃⌥⌘M mutes and unmutes the app in front (\(front.localizedName ?? id))")
            HotKeys.shared.trigger(3)
            await wait(0.3)
            expect(abs((model.rules[id]?.volume ?? 0) - 1.1) < 0.001, "⌃⌥⌘↑ raises the app in front to 110% (\(HUD.lastMessage ?? "-"))")
            HotKeys.shared.trigger(4)
            await wait(0.3)
            expect(model.rules[id] == nil, "⌃⌥⌘↓ brings it back to 100%")
        } else {
            say("  (skipping app-in-front shortcuts: no other app in front)")
        }

        // ---- Hardware balance on the built-in speakers.
        if let original = builtIn.balance {
            model.setBalance(0.25, for: builtIn)
            let readBack = CA.get(builtIn.id, DeviceManager.balanceAddress, Float32(0)) ?? -1
            expect(abs(readBack - 0.25) < 0.05, "speaker balance set and read back (\(readBack))")
            model.setBalance(original, for: builtIn)
        } else {
            say("  (built-in speakers have no hardware balance)")
        }

        // ---- "Disconnect" the test speaker.
        if let originalDefault { DeviceManager.setDefaultOutput(originalDefault) }
        AudioHardwareDestroyAggregateDevice(testDevice)
        await wait(2.5)
        expect(model.device(testUID) == nil, "test speaker removed")
        expect(model.rules["test.preset.b"]?.volume == 0.25, "automation on disconnect: applied preset “Test Disconnect”")

        // ---- Restore.
        for p in model.presets where !originalPresets.contains(p.id) { model.deletePreset(p.id) }
        for a in model.automations where !originalAutomations.contains(a.id) { model.deleteAutomation(a.id) }
        for id in Set(model.rules.keys).union(originalRules.keys) { model.setRule(originalRules[id], forAppID: id) }
        if let originalDefault { DeviceManager.setDefaultOutput(originalDefault) }
        if originalAlerts.isEmpty {
            if let originalSystem { DeviceManager.setSystemOutput(originalSystem) }
            UserDefaults.standard.set("", forKey: "alertsSetting")
        } else {
            model.setAlertsDevice(originalAlerts == "default" ? nil : originalAlerts)
        }
        await wait(0.5)
        say("restored: default=\(model.defaultDevice?.name ?? "?"), alerts=\(model.alertsDevice?.name ?? "?"), presets=\(model.presets.count), automations=\(model.automations.count), rules=\(model.rules.count)")
        finish()

        func finish() {
            say(failures == 0 ? "ALL PASSED" : "\(failures) FAILURE(S)")
            try? log.write(toFile: logPath, atomically: true, encoding: .utf8)
            exit(failures == 0 ? 0 : 1)
        }
    }
}

extension SelfTest {
    /// A spoken clip for audio tests.
    static func speechFile() -> String {
        let path = NSTemporaryDirectory() + "soundrouter-feature.aiff"
        if !FileManager.default.fileExists(atPath: path) {
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-o", path, String(repeating: "Sound router feature test. ", count: 14)]
            try? say.run(); say.waitUntilExit()
        }
        return path
    }
}

/// Launches a process that is "responsible" for itself (not SoundRouter), so it shows up
/// as its own app in the audio process list, like a normal app would.
enum SpawnDisclaimed {
    private typealias DisclaimFn = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
    private static let disclaim: DisclaimFn? = {
        guard let h = dlopen(nil, RTLD_NOW), let s = dlsym(h, "responsibility_spawnattrs_setdisclaim") else { return nil }
        return unsafeBitCast(s, to: DisclaimFn.self)
    }()

    static func run(_ path: String, _ args: [String]) throws -> pid_t {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        _ = disclaim?(&attr, 1)
        var pid: pid_t = 0
        let argv = ([path] + args).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let rc = posix_spawn(&pid, path, nil, &attr, argv, environ)
        guard rc == 0 else { throw CAError(what: "posix_spawn", status: rc) }
        return pid
    }
}

/// `SoundRouter --fullscreentest <log> <helper binary>`: puts a helper app's window in full
/// screen, then opens the menu bar panel on top of it, with SoundRouter's window open and closed.
enum FullScreenTest {
    @MainActor static func run(_ logPath: String, helper: String, delegate: AppDelegate) async {
        var log = ""
        var failures = 0
        func say(_ s: String) { log += s + "\n"; print(s) }
        func expect(_ ok: Bool, _ what: String) { say((ok ? "PASS " : "FAIL ") + what); if !ok { failures += 1 } }
        func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }

        /// Is the helper's full-screen window on screen (i.e. we're still on its Space)?
        func helperOnScreen(_ number: Int) -> Bool {
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            return list.contains { ($0[kCGWindowNumber as String] as? Int) == number }
        }

        let marker = NSTemporaryDirectory() + "soundrouter-fullscreen-\(getpid())"
        try? FileManager.default.removeItem(atPath: marker)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = [marker]
        try? process.run()
        var windowNumber: Int?
        for _ in 0..<40 {
            await wait(0.25)
            if let s = try? String(contentsOfFile: marker, encoding: .utf8), let n = Int(s) { windowNumber = n; break }
        }
        guard let windowNumber, let statusBar = delegate.statusBar else {
            expect(false, "helper app entered full screen")
            finish()
            return
        }
        await wait(1.5)   // let the Space transition finish
        expect(helperOnScreen(windowNumber), "helper app is full screen and showing")

        for (label, closeWindow) in [("SoundRouter window open", false), ("SoundRouter window closed", true)] {
            if closeWindow { delegate.mainWindow?.performClose(nil); await wait(0.5) }
            statusBar.toggle()   // what clicking the menu bar icon does
            await wait(1.2)
            let window = statusBar.popover.contentViewController?.view.window
            let shown = statusBar.popover.isShown && window?.isVisible == true
            let onSpace = window?.isOnActiveSpace == true
            let stayed = helperOnScreen(windowNumber)
            say("  \(label): panel shown=\(shown), on current Space=\(onSpace), still on full-screen app=\(stayed)")
            expect(shown && onSpace && stayed, "\(label): menu bar panel opens over the full-screen app")
            if statusBar.popover.isShown { statusBar.toggle() }
            await wait(0.6)
        }

        process.terminate()
        try? FileManager.default.removeItem(atPath: marker)
        finish()

        func finish() {
            say(failures == 0 ? "ALL PASSED" : "\(failures) FAILURE(S)")
            try? log.write(toFile: logPath, atomically: true, encoding: .utf8)
            exit(failures == 0 ? 0 : 1)
        }
    }
}
