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
