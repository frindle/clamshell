// Tests for Sources/Clamshell/Resources/webclient/input.js and audio.js
import { test } from 'node:test';
import assert from 'node:assert';
import { HeldKeys, isModifier, reconnectDelay, frameAction } from '../Sources/Clamshell/Resources/webclient/input.js';
import { scheduleAt, AAC_CONFIG, audioSupported } from '../Sources/Clamshell/Resources/webclient/audio.js';

test('a plain keyup releases just that key', () => {
  const h = new HeldKeys();
  h.press('KeyA', 0);
  h.press('ShiftLeft', 56);
  assert.deepStrictEqual(h.release('KeyA'), [0]);
  assert.strictEqual(h.size, 1);
  assert.deepStrictEqual(h.release('KeyA'), []);
});

test('releasing Cmd also releases keys whose keyup the browser swallowed', () => {
  const h = new HeldKeys();
  h.press('MetaLeft', 55);
  h.press('ShiftLeft', 56);
  h.press('KeyC', 8);
  // Cmd comes up; the C keyup never arrived. Shift is still really held.
  assert.deepStrictEqual(h.release('MetaLeft'), [8, 55]);
  assert.strictEqual(h.size, 1);
  assert.deepStrictEqual(h.release('ShiftLeft'), [56]);
});

test('releaseAll lets go of keys before modifiers and empties the set', () => {
  const h = new HeldKeys();
  h.press('MetaLeft', 55);
  h.press('Tab', 48);
  assert.deepStrictEqual(h.releaseAll(), [48, 55]);
  assert.strictEqual(h.size, 0);
  assert.deepStrictEqual(h.releaseAll(), []);
});

test('isModifier', () => {
  for (const c of ['ShiftLeft', 'ControlRight', 'AltLeft', 'MetaRight', 'CapsLock']) assert.ok(isModifier(c), c);
  for (const c of ['KeyA', 'Tab', 'Escape', 'F1']) assert.ok(!isModifier(c), c);
});

test('reconnectDelay backs off 1,2,4,8 then caps at 10', () => {
  assert.deepStrictEqual([1, 2, 3, 4, 5, 6, 20].map(reconnectDelay), [1, 2, 4, 8, 10, 10, 10]);
  assert.strictEqual(reconnectDelay(0), 1);
});

test('frameAction decodes normally', () => {
  assert.strictEqual(frameAction({ keyframe: false, waitingForKey: false, queueSize: 0, hidden: false }), 'decode');
  assert.strictEqual(frameAction({ keyframe: true, waitingForKey: true, queueSize: 50, hidden: false }), 'decode');
});

test('frameAction resyncs once on a backlog, then skips until the keyframe', () => {
  assert.strictEqual(frameAction({ keyframe: false, waitingForKey: false, queueSize: 7, hidden: false }), 'resync');
  assert.strictEqual(frameAction({ keyframe: false, waitingForKey: true, queueSize: 7, hidden: false }), 'skip');
  assert.strictEqual(frameAction({ keyframe: false, waitingForKey: false, queueSize: 6, hidden: false }), 'decode');
});

test('frameAction decodes nothing in a hidden tab', () => {
  assert.strictEqual(frameAction({ keyframe: true, waitingForKey: false, queueSize: 0, hidden: true }), 'skip');
  assert.strictEqual(frameAction({ keyframe: false, waitingForKey: false, queueSize: 0, hidden: true }), 'skip');
});

test('scheduleAt starts ahead of now when nothing is queued', () => {
  const r = scheduleAt(10, 0);
  assert.strictEqual(r.drop, false);
  assert.ok(Math.abs(r.at - 10.08) < 1e-9);
});

test('scheduleAt queues back to back, and drops when sound would lag', () => {
  assert.deepStrictEqual(scheduleAt(10, 10.1), { at: 10.1, drop: false });
  assert.strictEqual(scheduleAt(10, 10.5).drop, true);
  // Fell behind (underrun): restart ahead of now rather than in the past.
  assert.ok(scheduleAt(10, 9.9).at > 10);
});

test('AAC config is AAC-LC, 48 kHz, stereo', () => {
  const bits = (AAC_CONFIG[0] << 8) | AAC_CONFIG[1];
  assert.strictEqual(bits >> 11, 2);          // object type: AAC-LC
  assert.strictEqual((bits >> 7) & 0xf, 3);   // frequency index: 48000
  assert.strictEqual((bits >> 3) & 0xf, 2);   // channels: stereo
});

test('audioSupported is false without WebCodecs (node)', () => {
  assert.strictEqual(audioSupported(), false);
});
