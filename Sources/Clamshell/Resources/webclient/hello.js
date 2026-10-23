// Pure helpers for the client display report the browser client sends the
// host (PROTOCOL.md: HELLO trailing bytes / CLIENT_DISPLAYS). No DOM access
// at load time, so `node --test` can import this module directly.

// Client size in device pixels: css size x devicePixelRatio, landscape-normalized,
// clamped to the host's 640x480 minimum.
export function screenPx(cssW, cssH, dpr) {
  const ratio = (typeof dpr === 'number' && isFinite(dpr) && dpr > 0) ? dpr : 1;
  const pw = Math.round(cssW * ratio);
  const ph = Math.round(cssH * ratio);
  const w = Math.max(pw, ph);
  const h = Math.min(pw, ph);
  return { w: Math.max(w, 640), h: Math.max(h, 480) };
}

// HELLO payload: version(1)=1, requestedCodec(1)=1 (H.264), widthPx(4 BE), heightPx(4 BE), flags(1)=0.
export function helloPayload(cssW, cssH, dpr) {
  const { w, h } = screenPx(cssW, cssH, dpr);
  const buf = new Uint8Array(11);
  const dv = new DataView(buf.buffer, buf.byteOffset);
  dv.setUint8(0, 1);       // version
  dv.setUint8(1, 1);       // requestedCodec = H.264
  dv.setUint32(2, w, false);
  dv.setUint32(6, h, false);
  dv.setUint8(10, 0);      // flags
  return buf;
}

// CLIENT_DISPLAYS payload: widthPx(4 BE), heightPx(4 BE), flags(1)=0.
export function clientDisplaysPayload(cssW, cssH, dpr) {
  const { w, h } = screenPx(cssW, cssH, dpr);
  const buf = new Uint8Array(9);
  const dv = new DataView(buf.buffer, buf.byteOffset);
  dv.setUint32(0, w, false);
  dv.setUint32(4, h, false);
  dv.setUint8(8, 0);       // flags
  return buf;
}

// Trailing-edge debounce over an injectable timer pair.
export function debounce(fn, ms, timers = globalThis) {
  let timerId = null;
  let args = [];
  return (...a) => {
    args = a;
    if (timerId !== null) timers.clearTimeout(timerId);
    timerId = timers.setTimeout(() => {
      timerId = null;
      fn(...args);
    }, ms);
  };
}

// Re-report the window size to the host after the window stops resizing.
export function attachResizeReporter(win, sendPayload, ms = 250, timers = globalThis) {
  const handler = debounce(() => {
    sendPayload(clientDisplaysPayload(win.innerWidth, win.innerHeight, win.devicePixelRatio));
  }, ms, timers);
  win.addEventListener('resize', handler);
  return handler;
}
