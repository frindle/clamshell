// Pure input helpers for the browser client. No DOM access at load time, so
// `node --test` can import this module directly.

// Tracks which keys the host currently believes are down, so they can all be
// released when the browser stops telling us about them. Two cases matter:
//  - the window loses focus mid-chord (Cmd-Tab away): no keyup ever arrives,
//    and the host is left with Cmd held down;
//  - macOS browsers never fire keyup for a key released while Cmd is held
//    (Cmd-C: the C keyup is swallowed), so those are released with Cmd.
export class HeldKeys {
  constructor() { this.down = new Map(); } // KeyboardEvent.code -> mac keycode

  press(code, vk) { this.down.set(code, vk); }

  /// Returns the keycodes to release for this keyup (the key itself, plus
  /// everything else still held when a Cmd key comes up).
  release(code) {
    const out = [];
    if (code === 'MetaLeft' || code === 'MetaRight') {
      for (const [c, vk] of this.down) {
        if (isModifier(c)) continue;
        out.push(vk);
        this.down.delete(c);
      }
    }
    if (this.down.has(code)) { out.push(this.down.get(code)); this.down.delete(code); }
    return out;
  }

  /// Everything still held, non-modifiers first so the host sees e.g. "C up"
  /// before "Cmd up". Clears the set.
  releaseAll() {
    const keys = [], mods = [];
    for (const [c, vk] of this.down) (isModifier(c) ? mods : keys).push(vk);
    this.down.clear();
    return keys.concat(mods);
  }

  get size() { return this.down.size; }
}

export function isModifier(code) {
  return /^(Shift|Control|Alt|Meta)(Left|Right)$/.test(code) || code === 'CapsLock';
}

// Reconnect delay in seconds for the nth attempt in a row: 1, 2, 4, 8, 10, 10…
export function reconnectDelay(attempt) {
  return Math.min(2 ** Math.max(0, attempt - 1), 10);
}

// Decide what to do with an incoming video frame.
//  'decode'  — hand it to the decoder
//  'skip'    — drop it (waiting for a keyframe)
//  'resync'  — drop it and ask the host for a keyframe
// The decoder falls behind when the tab was throttled or the machine is busy;
// decoding the backlog in order just shows the past. Dropping to the next
// keyframe gets back to "now". A hidden tab decodes nothing at all.
export function frameAction({ keyframe, waitingForKey, queueSize, hidden, maxQueue = 6 }) {
  if (hidden) return 'skip';
  if (keyframe) return 'decode';
  if (waitingForKey) return 'skip';
  if (queueSize > maxQueue) return 'resync';
  return 'decode';
}

// ── Ctrl acts as Cmd (Windows / Linux keyboards) ───────────────────────
// On by default where the OS is Windows or Linux, so Ctrl-C / Ctrl-V / Ctrl-T
// do what Cmd-C / Cmd-V / Cmd-T do on the Mac.
export function ctrlAsCmdDefault(nav) {
  if (!nav) return false;
  const p = (nav.userAgentData && nav.userAgentData.platform) || nav.platform || '';
  return /win|linux/i.test(p) && !/android/i.test(p);
}

// Mac key code to send for a key. With the toggle on, Control sends Command
// and the Windows key sends Control (left stays left, right stays right), so
// real Control shortcuts (Ctrl-C in Terminal, Ctrl-A / Ctrl-E) stay reachable.
const SWAPPED = { ControlLeft: 55, ControlRight: 54, MetaLeft: 59, MetaRight: 62 };
export function remapKey(code, vk, ctrlAsCmd) {
  return ctrlAsCmd && code in SWAPPED ? SWAPPED[code] : vk;
}

// CGEventFlags for the current modifier state (state: {shift, ctrl, alt, meta, caps}).
// With the toggle on, Ctrl becomes Command and the Windows key becomes Control.
export function modifierFlags(state, ctrlAsCmd) {
  let f = 0n;
  if (state.caps) f |= 0x10000n;
  if (state.shift) f |= 0x20000n;
  if (ctrlAsCmd ? state.meta : state.ctrl) f |= 0x40000n;
  if (state.alt) f |= 0x80000n;
  if (ctrlAsCmd ? state.ctrl : state.meta) f |= 0x100000n;
  return f;
}

// ── Host capabilities ──────────────────────────────────────────────────
// Bits of the host's capability value (PROTOCOL.md). It is 0 until the
// handshake code calls setHostCapabilities(); at 0 the client sends only what
// every host understands.
export const CAP = {
  approvalRequired: 1 << 0,
  relativeMouse: 1 << 1,
  textInput: 1 << 2,
  extraButtons: 1 << 3,
  deviceApproval: 1 << 4,
  fileTransfer: 1 << 5,
  peripherals: 1 << 6,
  restart: 1 << 7,
  loginCredentials: 1 << 8,
};

let hostCaps = 0;
export function setHostCapabilities(bits) {
  hostCaps = Number.isInteger(bits) && bits > 0 ? bits >>> 0 : 0;
}
export function hostCapabilities() { return hostCaps; }
export function hostHas(bit) { return (hostCaps & bit) !== 0; }

// ── Message encoders (PROTOCOL.md "Input mapping") ─────────────────────
export const INPUT = {
  MOUSE_MOVE: 0x20, MOUSE_BUTTON: 0x21, KEY: 0x22, SCROLL: 0x23,
  MOUSE_RELATIVE: 0x24, TEXT: 0x25, MOUSE_BUTTON_AT_CURSOR: 0x26,
};
export const MAX_TEXT_BYTES = 16384;

function f32(v) {
  const b = new Uint8Array(4);
  new DataView(b.buffer).setFloat32(0, v, false);
  return b;
}

function concatBytes(...parts) {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
}

/// [type][4-byte big-endian length][payload]
export function frameMessage(type, payload = new Uint8Array(0)) {
  const buf = new Uint8Array(5 + payload.length);
  buf[0] = type;
  new DataView(buf.buffer).setUint32(1, payload.length, false);
  buf.set(payload, 5);
  return buf;
}

export function encodeMouseMove(x, y) {
  return frameMessage(INPUT.MOUSE_MOVE, concatBytes(f32(x), f32(y)));
}

export function encodeMouseButton(button, down, x, y) {
  return frameMessage(INPUT.MOUSE_BUTTON,
    concatBytes(new Uint8Array([button, down ? 1 : 0]), f32(x), f32(y)));
}

export function encodeKey(macVK, down, flags) {
  const b = new Uint8Array(11);
  const v = new DataView(b.buffer);
  v.setUint16(0, macVK, false);
  b[2] = down ? 1 : 0;
  v.setBigUint64(3, BigInt(flags), false);
  return frameMessage(INPUT.KEY, b);
}

export function encodeScroll(dx, dy) {
  return frameMessage(INPUT.SCROLL, concatBytes(f32(dx), f32(dy)));
}

/// Pointer movement in points, for a captured pointer. Host needs relativeMouse.
export function encodeMouseRelative(dx, dy) {
  return frameMessage(INPUT.MOUSE_RELATIVE, concatBytes(f32(dx), f32(dy)));
}

/// A press or release where the host cursor is. Host needs relativeMouse.
export function encodeButtonAtCursor(button, down) {
  return frameMessage(INPUT.MOUSE_BUTTON_AT_CURSOR, new Uint8Array([button, down ? 1 : 0]));
}

/// Text to type as-is. Returns null when it is longer than the limit (the host
/// would ignore it). Host needs textInput; nothing in the client sends it yet.
export function encodeText(text) {
  const bytes = new TextEncoder().encode(text);
  if (bytes.length > MAX_TEXT_BYTES) return null;
  return frameMessage(INPUT.TEXT, bytes);
}

// ── Mouse buttons ──────────────────────────────────────────────────────
// Browser MouseEvent.button: 0 left, 1 middle, 2 right, 3 back, 4 forward.
// Protocol: 0 left, 1 right, 2 middle, 3 back, 4 forward.
const BROWSER_TO_PROTOCOL = [0, 2, 1, 3, 4];

/// The protocol button for a browser button, or null if this host should not
/// be sent it. Without extraButtons only left and right go out, as before.
export function protocolButton(browserButton, caps = hostCaps) {
  const b = BROWSER_TO_PROTOCOL[browserButton];
  if (b === undefined) return null;
  if (b >= 2 && (caps & CAP.extraButtons) === 0) return null;
  return b;
}

/// Whether the browser's own action for this button (back/forward navigation,
/// middle-click autoscroll) must be stopped because the host takes the button.
export function claimsButton(browserButton, caps = hostCaps) {
  const b = protocolButton(browserButton, caps);
  return b !== null && b >= 2;
}

// ── Keepalive ──────────────────────────────────────────────────────────
// The host drops a connection whose sends stall for 15 s (SendPacer), which
// is about the host's own sends and does not look at the client being quiet.
// A tunnel, though, can drop a connection with no traffic at all, and a
// still screen sends no video. So when the client has sent nothing for
// `idleMs`, it sends a PING (type 0x07, empty); the host echoes it.
export const KEEPALIVE_IDLE_MS = 20000;
export function keepaliveDue(now, lastSentAt, idleMs = KEEPALIVE_IDLE_MS) {
  return now - lastSentAt >= idleMs;
}
