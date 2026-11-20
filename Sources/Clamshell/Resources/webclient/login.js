// Login window (LOGIN_CREDENTIALS, PROTOCOL.md "Login window") and the
// password-manager-friendly forms the page uses for it and for Restart.
// No DOM access at load time, so `node --test` can import this directly.
//
// The password is never stored by this code (no localStorage, no IndexedDB),
// never logged, and is cleared from the form right after it is sent.

export const LOGIN_CREDENTIALS = 0x5C;
export const LOGIN_MIN_INTERVAL_MS = 3000; // the host ignores a second message sooner than this
export const LOGIN_MAX_FIELD_BYTES = 512;
export const LOGIN_MAX_PAYLOAD_BYTES = 2048;

const enc = new TextEncoder();

// The host's rule: 1 to 512 UTF-8 bytes, no control characters
// (below 0x20, 0x7F, or 0x80 to 0x9F).
export function validField(s) {
  if (typeof s !== 'string' || s.length === 0) return false;
  if (enc.encode(s).length > LOGIN_MAX_FIELD_BYTES) return false;
  for (const ch of s) {
    const c = ch.codePointAt(0);
    if (c < 0x20 || c === 0x7F || (c >= 0x80 && c < 0xA0)) return false;
  }
  return true;
}

// The wire payload, or null when the host would ignore it.
export function loginPayload(user, password) {
  if (!validField(user) || !validField(password)) return null;
  const body = enc.encode(JSON.stringify({ v: 1, kind: 'login', user, password }));
  return body.length <= LOGIN_MAX_PAYLOAD_BYTES ? body : null;
}

// Client-side twin of the host's 3 second rule, so a double click does not
// make the host drop the one that matters.
export class LoginLimiter {
  constructor(now = () => Date.now(), minMs = LOGIN_MIN_INTERVAL_MS) { this.now = now; this.minMs = minMs; this.last = null; }
  waitMs() { return this.last === null ? 0 : Math.max(0, this.minMs - (this.now() - this.last)); }
  tryTake() { if (this.waitMs() > 0) return false; this.last = this.now(); return true; }
}

// What to tell the person when a form cannot be sent.
export function loginProblem(user, password, limiter) {
  if (!validField(user) || !validField(password)) {
    return 'Enter the account name and password. Neither can be empty, contain a line break or tab, or be longer than 512 bytes.';
  }
  const w = limiter ? limiter.waitMs() : 0;
  if (w > 0) return `Wait ${Math.ceil(w / 1000)} s before sending again.`;
  return null;
}

// A real <form> that Vaultwarden and other password managers fill:
// username (autocomplete="username") and password (current-password), with
// name and id set. `doc` is the document (injectable for tests). Returns
// { form, user, pass, submitButton }. The submit button lives in the form;
// the page's own buttons need not be used.
export function buildCredentialForm(doc, { id, submitLabel, onSubmit, userPlaceholder = 'Mac user name' }) {
  const form = doc.createElement('form');
  form.id = id;
  form.method = 'post';
  form.action = '#';
  form.setAttribute('autocomplete', 'on');
  const user = doc.createElement('input');
  user.type = 'text'; user.id = id + 'User'; user.name = 'username';
  user.setAttribute('autocomplete', 'username');
  user.setAttribute('autocapitalize', 'none'); user.setAttribute('autocorrect', 'off');
  user.spellcheck = false; user.placeholder = userPlaceholder;
  const pass = doc.createElement('input');
  pass.type = 'password'; pass.id = id + 'Password'; pass.name = 'password';
  pass.setAttribute('autocomplete', 'current-password');
  pass.placeholder = 'Password';
  const submitButton = doc.createElement('button');
  submitButton.type = 'submit'; submitButton.textContent = submitLabel;
  form.append(user, pass, submitButton);
  form.addEventListener('submit', (e) => {
    e.preventDefault();
    onSubmit(user.value, pass.value, { user, pass, form });
  });
  return { form, user, pass, submitButton };
}
