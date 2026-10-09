// Collects the tab's audio into ~10 ms interleaved stereo chunks and posts them,
// prefixed with the header the SoundRouter app expects.
class TabTap extends AudioWorkletProcessor {
  constructor(options) {
    super();
    const { tabId, chunkFrames } = options.processorOptions;
    this.tabId = tabId;
    this.frames = chunkFrames;
    this.reset();
  }

  reset() {
    this.buf = new ArrayBuffer(8 + this.frames * 2 * 4);
    const header = new Uint32Array(this.buf, 0, 2);
    header[0] = this.tabId;
    header[1] = 2;
    this.samples = new Float32Array(this.buf, 8);
    this.filled = 0;
  }

  process(inputs) {
    const input = inputs[0];
    if (!input || input.length === 0) return true;
    const left = input[0];
    const right = input[1] || input[0];
    for (let i = 0; i < left.length; i++) {
      this.samples[this.filled * 2] = left[i];
      this.samples[this.filled * 2 + 1] = right[i];
      if (++this.filled === this.frames) {
        this.port.postMessage(this.buf, [this.buf]);
        this.reset();
      }
    }
    return true;
  }
}

registerProcessor('tab-tap', TabTap);
