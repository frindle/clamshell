// Full screen for the browser client. No DOM access at import time, so
// tests/test-webclient-fullscreen.js runs these in Node with stand-in objects.
//
// Three cases:
// - The browser can put a page in full screen (desktop browsers, Android,
//   iPad Safari): the menu toggles it, and "Start in full screen" does it on
//   the first click or tap on the screen.
// - The page was opened from a Home Screen icon or an installed app window:
//   there are no browser bars to hide.
// - The browser cannot (Safari and the other browsers on iPhone): the menu
//   explains Add to Home Screen. manifest.webmanifest and the apple-mobile-web-app
//   tags in index.html make that icon open without browser bars.

// The Fullscreen API, standard or WebKit-prefixed (iPad Safari before 16.4
// has only the prefixed names), or null when this page can't use it.
export function fullscreenApi(doc) {
  const el = doc && doc.documentElement;
  if (!el) return null;
  if (typeof el.requestFullscreen === 'function' && typeof doc.exitFullscreen === 'function'
    && doc.fullscreenEnabled !== false) {
    return {
      active: () => !!doc.fullscreenElement,
      enter: () => Promise.resolve(el.requestFullscreen()),
      exit: () => Promise.resolve(doc.exitFullscreen()),
      events: ['fullscreenchange'],
    };
  }
  if (typeof el.webkitRequestFullscreen === 'function' && typeof doc.webkitExitFullscreen === 'function'
    && doc.webkitFullscreenEnabled !== false) {
    return {
      active: () => !!(doc.webkitFullscreenElement || doc.webkitCurrentFullScreenElement),
      // The prefixed calls return nothing; errors arrive as an event instead.
      enter: () => Promise.resolve(el.webkitRequestFullscreen()),
      exit: () => Promise.resolve(doc.webkitExitFullscreen()),
      events: ['webkitfullscreenchange'],
    };
  }
  return null;
}

// Opened from a Home Screen icon or as an installed app: no browser bars.
export function isStandalone(win) {
  try {
    if (win.navigator && win.navigator.standalone === true) return true; // iOS
    if (typeof win.matchMedia !== 'function') return false;
    return win.matchMedia('(display-mode: fullscreen)').matches
      || win.matchMedia('(display-mode: standalone)').matches;
  } catch (e) {
    return false;
  }
}

// What the menu's Full screen item does: 'toggle', 'none' (hidden: already
// without bars) or 'homescreen' (shows how to add the page to the Home Screen).
export function fullscreenMode({ api, standalone }) {
  if (api) return 'toggle';
  return standalone ? 'none' : 'homescreen';
}

// "Start in full screen", kept per browser. Browsers allow full screen only
// from a click, tap or key press, so the first click or tap on the screen
// after the page opens does it. That click is not sent to the Mac.
export const START_FULLSCREEN_KEY = 'clamshell.startFullscreen';

export function loadStartFullscreen(store) {
  try { return !!store && store.getItem(START_FULLSCREEN_KEY) === '1'; } catch (e) { return false; }
}

export function saveStartFullscreen(store, on) {
  try { if (store) store.setItem(START_FULLSCREEN_KEY, on ? '1' : '0'); } catch (e) { /* ignore */ }
}

// Whether this click or tap should enter full screen instead of reaching the
// Mac. Once per page load: after leaving full screen (Esc), clicks go to the
// Mac again until the page is reloaded.
export function shouldAutoEnter({ pref, api, standalone, used }) {
  return !!pref && !!api && !standalone && !used && !api.active();
}
