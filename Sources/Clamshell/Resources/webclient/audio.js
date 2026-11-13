// Plays the host's system audio in the browser. The wire carries bare AAC-LC
// access units at a fixed 48 kHz stereo (PROTOCOL.md "Audio"), so the decoder
// is configured with a synthesized AudioSpecificConfig instead of one from
// the stream. Off until the user turns sound on: browsers only allow audio
// to start from a click.

export const AAC_SAMPLE_RATE = 48000;
export const AAC_FRAME_SAMPLES = 1024;
// AudioSpecificConfig: object type 2 (AAC-LC), frequency index 3 (48 kHz),
// channel configuration 2 (stereo) -> 00010 0011 0010 000.
export const AAC_CONFIG = new Uint8Array([0x11, 0x90]);

// Where to schedule the next decoded buffer. Pure, so it is unit-tested.
//  - nothing queued (or we fell behind): start a little ahead of "now" so
//    network jitter doesn't cause gaps;
//  - too much queued (sound would lag the picture): drop this buffer.
export function scheduleAt(now, playAt, { lead = 0.08, maxAhead = 0.4 } = {}) {
  if (playAt < now + 0.01) return { at: now + lead, drop: false };
  if (playAt > now + maxAhead) return { at: playAt, drop: true };
  return { at: playAt, drop: false };
}

export function audioSupported() {
  return typeof AudioDecoder !== 'undefined' &&
    (typeof AudioContext !== 'undefined' || typeof webkitAudioContext !== 'undefined');
}

export class AudioPlayer {
  constructor() { this.ctx = null; this.dec = null; this.playAt = 0; this.ts = 0; this.on = false; }

  /// Call from a click handler. Returns false if this browser can't do it.
  async start() {
    if (!audioSupported()) return false;
    try {
      const support = await AudioDecoder.isConfigSupported(this.config());
      if (!support.supported) return false;
      const Ctx = typeof AudioContext !== 'undefined' ? AudioContext : webkitAudioContext;
      this.ctx = new Ctx({ latencyHint: 'interactive' });
      await this.ctx.resume();
      this.openDecoder();
      this.on = true;
      return true;
    } catch (e) {
      console.error('[Clamshell] audio start failed', e);
      this.stop();
      return false;
    }
  }

  config() {
    return { codec: 'mp4a.40.2', sampleRate: AAC_SAMPLE_RATE, numberOfChannels: 2, description: AAC_CONFIG };
  }

  openDecoder() {
    this.dec = new AudioDecoder({
      output: (data) => this.play(data),
      error: (e) => { console.error('[Clamshell] audio decoder error', e); this.dec = null; },
    });
    this.dec.configure(this.config());
    this.ts = 0;
  }

  stop() {
    this.on = false;
    try { if (this.dec && this.dec.state !== 'closed') this.dec.close(); } catch (e) {}
    try { if (this.ctx) this.ctx.close(); } catch (e) {}
    this.dec = null; this.ctx = null; this.playAt = 0;
  }

  /// A new connection starts a new AAC stream; start the decoder fresh.
  reset() {
    if (!this.on) return;
    try { if (this.dec && this.dec.state !== 'closed') this.dec.close(); } catch (e) {}
    try { this.openDecoder(); } catch (e) { this.dec = null; }
  }

  /// One AAC access unit from an AUDIO_FRAME message.
  push(bytes) {
    if (!this.on || !this.ctx) return;
    if (!this.dec) { try { this.openDecoder(); } catch (e) { return; } }
    if (this.dec.decodeQueueSize > 20) return; // far behind; let it drain
    const duration = Math.round(AAC_FRAME_SAMPLES * 1e6 / AAC_SAMPLE_RATE);
    try {
      this.dec.decode(new EncodedAudioChunk({ type: 'key', timestamp: this.ts, duration, data: bytes }));
      this.ts += duration;
    } catch (e) {
      console.error('[Clamshell] audio decode() threw', e);
      this.dec = null;
    }
  }

  play(data) {
    const ctx = this.ctx;
    if (!ctx || !this.on) { data.close(); return; }
    try {
      const frames = data.numberOfFrames, channels = data.numberOfChannels;
      const buf = ctx.createBuffer(channels, frames, data.sampleRate);
      const plane = new Float32Array(frames);
      for (let c = 0; c < channels; c++) {
        data.copyTo(plane, { planeIndex: c, format: 'f32-planar' });
        buf.copyToChannel(plane, c);
      }
      const { at, drop } = scheduleAt(ctx.currentTime, this.playAt);
      if (drop) return;
      const src = ctx.createBufferSource();
      src.buffer = buf;
      src.connect(ctx.destination);
      src.start(at);
      this.playAt = at + buf.duration;
    } catch (e) {
      console.error('[Clamshell] audio play failed', e);
    } finally {
      data.close();
    }
  }
}
