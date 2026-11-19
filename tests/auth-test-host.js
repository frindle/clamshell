// A host's half of the handshake, in memory, for the web client's tests. It is
// written from PROTOCOL.md using the primitives in auth.js, so it checks the
// client against the spec rather than against itself only (the vectors in
// tests/vectors/auth-v1.json pin the bytes; the real Mac host is exercised by
// tests/test-webclient-auth-interop.js in CI).
import {
  AUTH, MSG, STATUS, bytes, concat, encodeHello, frame, parseChallenge, hostSignatureInput,
  clientSignatureInput, verifySignature, keyId, fingerprintOfId, generateEphemeral,
  deriveSessionMaterial, importSessionKey, Sealer, Opener, secureNonce,
} from '../Sources/Clamshell/Resources/webclient/auth.js';

const cr = globalThis.crypto;

export function b64u(b) {
  return btoa(String.fromCharCode(...b)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/** A signing key from a 32-byte scalar and its 65-byte public key (for the vectors). */
export async function signingKeyFrom(scalar, publicRaw) {
  const key = await cr.subtle.importKey('jwk', {
    kty: 'EC', crv: 'P-256', d: b64u(scalar), x: b64u(publicRaw.subarray(1, 33)), y: b64u(publicRaw.subarray(33, 65)),
  }, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
  return async (input) => new Uint8Array(await cr.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, input));
}

/** A fresh signing identity: { publicRaw, sign }. */
export async function newSigningIdentity() {
  const pair = await cr.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign', 'verify']);
  return {
    publicRaw: new Uint8Array(await cr.subtle.exportKey('raw', pair.publicKey)),
    sign: async (input) => new Uint8Array(await cr.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, pair.privateKey, input)),
  };
}

export class TestHost {
  static async create({ caps = 0b11011, name = 'Studio', identity, ephemeral, nonce, extensions = [] } = {}) {
    const h = new TestHost();
    h.identity = identity || await newSigningIdentity();
    h.ephemeral = ephemeral || await generateEphemeral(cr);
    h.nonce = nonce || cr.getRandomValues(new Uint8Array(AUTH.nonceBytes));
    h.caps = caps;
    h.payload = encodeHello({ caps, nonce: h.nonce, ephemeral: h.ephemeral.publicRaw,
      identity: h.identity.publicRaw, name, extensions });
    h.id = await keyId(h.identity.publicRaw, cr);
    h.fingerprint = fingerprintOfId(h.id);
    return h;
  }

  /** The AUTH_CHALLENGE message, framed. */
  challengeMessage() { return frame(MSG.AUTH_CHALLENGE, this.payload); }

  /** Checks a response payload the way a host does; throws when it is wrong. */
  async verifyResponse(responsePayload) {
    const body = responsePayload.subarray(0, responsePayload.length - AUTH.signatureBytes);
    const signature = responsePayload.subarray(responsePayload.length - AUTH.signatureBytes);
    const hello = parseChallenge(body);
    const ok = await verifySignature(signature, clientSignatureInput(this.payload, body), hello.identity, cr);
    if (!ok) throw new Error('the client signature does not verify');
    this.device = { ...hello, id: await keyId(hello.identity, cr), response: responsePayload };
    return this.device;
  }

  /** A signed AUTH_RESULT payload; busy and timeout cover an empty response. */
  async result(status, response = this.device.response) {
    const body = concat(Uint8Array.of(status), Uint8Array.of(0, 0));
    const covered = status === STATUS.busy || status === STATUS.timeout ? new Uint8Array(0) : response;
    const signature = await this.identity.sign(hostSignatureInput(this.payload, covered, body));
    return concat(body, signature);
  }

  resultMessage(status, response) { return this.result(status, response).then((p) => frame(MSG.AUTH_RESULT, p)); }

  /** After the response was verified: a sealer (host to client) and an opener (client to host). */
  async startSession(onWrite) {
    const m = await deriveSessionMaterial({
      privateKey: this.ephemeral.privateKey, peerPublic: this.device.ephemeral, hostNonce: this.nonce,
      clientNonce: this.device.nonce, challenge: this.payload, response: this.device.response,
    }, cr);
    this.keys = m;
    this.sealer = new Sealer(await importSessionKey(m.hostToClient, cr), onWrite, { cr });
    this.opener = new Opener(await importSessionKey(m.clientToHost, cr), { cr });
    return this;
  }

  /** The SECURE frame the host would send for `inner` (no checks on the inner type). */
  async rawSecureFrame(inner, counter) {
    const key = await importSessionKey(this.keys.hostToClient, cr);
    const ct = new Uint8Array(await cr.subtle.encrypt({ name: 'AES-GCM', iv: secureNonce(counter), tagLength: 128 }, key, inner));
    return frame(MSG.SECURE, ct);
  }

  /** Opens one SECURE message the client sent: `message` is the whole frame. */
  async openFromClient(message) {
    if (message[0] !== MSG.SECURE) throw new Error('not a SECURE message');
    return this.opener.open(message.subarray(5));
  }
}

/** Splits a whole framed message into its type and payload. */
export function unframe(message) {
  const len = new DataView(message.buffer, message.byteOffset, message.length).getUint32(1, false);
  if (message.length !== 5 + len) throw new Error('bad frame length');
  return { type: message[0], payload: message.subarray(5) };
}

export { bytes };
