// Tests for Sources/Clamshell/Resources/webclient/fullscreen.js
import { test } from 'node:test';
import assert from 'node:assert';
import {
  fullscreenApi, isStandalone, fullscreenMode, loadStartFullscreen, saveStartFullscreen, shouldAutoEnter,
  START_FULLSCREEN_KEY,
} from '../Sources/Clamshell/Resources/webclient/fullscreen.js';

function standardDoc() {
  const doc = { fullscreenElement: null, fullscreenEnabled: true, calls: [] };
  doc.documentElement = {
    requestFullscreen() { doc.calls.push('enter'); doc.fullscreenElement = this; return Promise.resolve(); },
  };
  doc.exitFullscreen = () => { doc.calls.push('exit'); doc.fullscreenElement = null; return Promise.resolve(); };
  return doc;
}

function webkitDoc() {
  const doc = { webkitFullscreenElement: null, calls: [] };
  doc.documentElement = {
    // The prefixed call returns nothing.
    webkitRequestFullscreen() { doc.calls.push('enter'); doc.webkitFullscreenElement = this; },
  };
  doc.webkitExitFullscreen = () => { doc.calls.push('exit'); doc.webkitFullscreenElement = null; };
  return doc;
}

function store() {
  const m = new Map();
  return { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)), m };
}

test('standard Fullscreen API: enter, active, exit', async () => {
  const doc = standardDoc();
  const fs = fullscreenApi(doc);
  assert.ok(fs);
  assert.deepStrictEqual(fs.events, ['fullscreenchange']);
  assert.strictEqual(fs.active(), false);
  await fs.enter();
  assert.strictEqual(fs.active(), true);
  await fs.exit();
  assert.strictEqual(fs.active(), false);
  assert.deepStrictEqual(doc.calls, ['enter', 'exit']);
});

test('older iPad Safari: the prefixed API works and its calls still give a promise', async () => {
  const doc = webkitDoc();
  const fs = fullscreenApi(doc);
  assert.ok(fs);
  assert.deepStrictEqual(fs.events, ['webkitfullscreenchange']);
  const p = fs.enter();
  assert.ok(p instanceof Promise);
  await p;
  assert.strictEqual(fs.active(), true);
  await fs.exit();
  assert.strictEqual(fs.active(), false);
});

test('the standard API wins when both exist', () => {
  const doc = standardDoc();
  doc.documentElement.webkitRequestFullscreen = () => { throw new Error('prefixed used'); };
  doc.webkitExitFullscreen = () => {};
  assert.deepStrictEqual(fullscreenApi(doc).events, ['fullscreenchange']);
});

test('no API (iPhone Safari), or full screen not allowed here: null', () => {
  assert.strictEqual(fullscreenApi({ documentElement: {} }), null);
  assert.strictEqual(fullscreenApi(null), null);
  const blocked = standardDoc();
  blocked.fullscreenEnabled = false; // e.g. a frame without allowfullscreen
  assert.strictEqual(fullscreenApi(blocked), null);
});

test('isStandalone: iOS Home Screen flag, display-mode media queries, or neither', () => {
  const mm = (match) => (q) => ({ matches: q === match });
  assert.strictEqual(isStandalone({ navigator: { standalone: true }, matchMedia: mm('') }), true);
  assert.strictEqual(isStandalone({ navigator: {}, matchMedia: mm('(display-mode: fullscreen)') }), true);
  assert.strictEqual(isStandalone({ navigator: {}, matchMedia: mm('(display-mode: standalone)') }), true);
  assert.strictEqual(isStandalone({ navigator: {}, matchMedia: mm('(display-mode: browser)') }), false);
  assert.strictEqual(isStandalone({ navigator: {} }), false);
  assert.strictEqual(isStandalone({ navigator: {}, matchMedia: () => { throw new Error('x'); } }), false);
});

test('fullscreenMode picks toggle, homescreen or none', () => {
  const api = fullscreenApi(standardDoc());
  assert.strictEqual(fullscreenMode({ api, standalone: false }), 'toggle');
  assert.strictEqual(fullscreenMode({ api, standalone: true }), 'toggle');
  assert.strictEqual(fullscreenMode({ api: null, standalone: false }), 'homescreen');
  assert.strictEqual(fullscreenMode({ api: null, standalone: true }), 'none');
});

test('Start in full screen is off by default and remembered per browser', () => {
  const st = store();
  assert.strictEqual(loadStartFullscreen(st), false);
  saveStartFullscreen(st, true);
  assert.strictEqual(st.m.get(START_FULLSCREEN_KEY), '1');
  assert.strictEqual(loadStartFullscreen(st), true);
  saveStartFullscreen(st, false);
  assert.strictEqual(loadStartFullscreen(st), false);
});

test('storage that is missing or throws never breaks the page', () => {
  const bad = { getItem() { throw new Error('denied'); }, setItem() { throw new Error('denied'); } };
  assert.strictEqual(loadStartFullscreen(bad), false);
  assert.strictEqual(loadStartFullscreen(null), false);
  saveStartFullscreen(bad, true);
  saveStartFullscreen(null, true);
});

test('shouldAutoEnter: only with the setting on, a usable API, once per page, not already full screen', () => {
  const doc = standardDoc();
  const api = fullscreenApi(doc);
  const base = { pref: true, api, standalone: false, used: false };
  assert.strictEqual(shouldAutoEnter(base), true);
  assert.strictEqual(shouldAutoEnter({ ...base, pref: false }), false);
  assert.strictEqual(shouldAutoEnter({ ...base, api: null }), false);
  assert.strictEqual(shouldAutoEnter({ ...base, standalone: true }), false);
  assert.strictEqual(shouldAutoEnter({ ...base, used: true }), false);
  doc.fullscreenElement = {};
  assert.strictEqual(shouldAutoEnter(base), false);
});
