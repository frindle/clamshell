// KeyboardEvent.code -> macOS virtual keycode (kVK_*).
// Direct port of ClamshellViewer/Sources/KeyMap.swift's hidToMacVK table
// (same target integers) keyed by the standard, layout-independent
// KeyboardEvent.code string instead of a USB HID usage id — the two use the
// same USB HID usage table underneath, so the values are identical.
export const codeToMacVK = {
  // Letters
  KeyA: 0, KeyB: 11, KeyC: 8, KeyD: 2, KeyE: 14, KeyF: 3, KeyG: 5, KeyH: 4,
  KeyI: 34, KeyJ: 38, KeyK: 40, KeyL: 37, KeyM: 46, KeyN: 45, KeyO: 31, KeyP: 35,
  KeyQ: 12, KeyR: 15, KeyS: 1, KeyT: 17, KeyU: 32, KeyV: 9, KeyW: 13, KeyX: 7,
  KeyY: 16, KeyZ: 6,
  // Digits
  Digit1: 18, Digit2: 19, Digit3: 20, Digit4: 21, Digit5: 23, Digit6: 22,
  Digit7: 26, Digit8: 28, Digit9: 25, Digit0: 29,
  // Whitespace / editing
  Enter: 36, Escape: 53, Backspace: 51, Tab: 48, Space: 49,
  // Punctuation
  Minus: 27, Equal: 24, BracketLeft: 33, BracketRight: 30, Backslash: 42,
  Semicolon: 41, Quote: 39, Backquote: 50, Comma: 43, Period: 47, Slash: 44,
  CapsLock: 57,
  // Function keys
  F1: 122, F2: 120, F3: 99, F4: 118, F5: 96, F6: 97,
  F7: 98, F8: 100, F9: 101, F10: 109, F11: 103, F12: 111,
  // Nav cluster
  Insert: 114, Home: 115, PageUp: 116, Delete: 117, End: 119, PageDown: 121,
  // Arrows
  ArrowRight: 124, ArrowLeft: 123, ArrowDown: 125, ArrowUp: 126,
  // Modifiers
  ControlLeft: 59, ShiftLeft: 56, AltLeft: 58, MetaLeft: 55,
  ControlRight: 62, ShiftRight: 60, AltRight: 61, MetaRight: 54,
};
