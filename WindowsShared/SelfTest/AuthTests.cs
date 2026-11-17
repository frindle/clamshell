using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Clamshell.Auth;

/// <summary>Vectors (tests/vectors/auth-v1.json), a full handshake for each
/// status, and tampered, reordered and replayed frames.</summary>
public static class AuthTests
{
    public static void Run(TestRun t, string vectorsPath)
    {
        using var doc = JsonDocument.Parse(File.ReadAllBytes(vectorsPath));
        var root = doc.RootElement;
        t.Group("wire helpers", () => WireHelpers(t));
        t.Group("vectors", () => Vectors(t, root));
        t.Group("handshake per status", () => HandshakePerStatus(t));
        t.Group("host refuses bad responses", () => HostRefuses(t));
        t.Group("client refuses bad challenges and results", () => ClientRefuses(t));
        t.Group("secure frames", () => SecureFrames(t));
    }

    private static byte[] H(JsonElement e, string name)
    {
        var text = e.GetProperty(name).GetString() ?? throw new InvalidOperationException(name);
        return Hex.Decode(text) ?? throw new InvalidOperationException(name + " is not hex");
    }

    private static string S(JsonElement e, string name) => e.GetProperty(name).GetString() ?? "";

    // MARK: wire helpers

    private static void WireHelpers(TestRun t)
    {
        t.Equal(Hex.Encode(new byte[] { 0x00, 0xAB, 0xFF }), "00abff", "hex encode is lowercase");
        t.Check(Hex.Decode("00AbFf") is { } d && Wire.SameBytes(d, new byte[] { 0, 0xAB, 0xFF }), "hex decode accepts either case");
        t.Check(Hex.Decode("abc") is null, "hex decode refuses an odd length");
        t.Check(Hex.Decode("zz") is null, "hex decode refuses other characters");
        t.Equal(DeviceIdentity.Fingerprint("2bad0fd610d99eae443e932a26142bca1e5fa995b4518452827e78ef1f317ff0"),
            "2BAD-0FD6-10D9-9EAE", "fingerprint is 16 upper-case characters in fours");
        t.Check(DeviceIdentity.IsWellFormedId(new string('a', 64)), "well-formed id");
        t.Check(!DeviceIdentity.IsWellFormedId(new string('A', 64)), "an upper-case id is not well-formed");
        t.Check(!DeviceIdentity.IsWellFormedId(new string('a', 63)), "a short id is not well-formed");

        t.Equal(AuthWire.CleanName("  Studio  "), "Studio", "name: spaces at both ends go");
        t.Equal(AuthWire.CleanName("Stu\u0000di\u0007o"), "Studio", "name: control characters go");
        t.Equal(AuthWire.CleanName("‮oiduTS"), "oiduTS", "name: a bidirectional override goes");
        t.Equal(AuthWire.CleanName("Stu​dio"), "Studio", "name: a zero-width space goes");
        t.Equal(AuthWire.CleanName("A B C"), "ABC", "name: line and paragraph separators go");
        t.Equal(AuthWire.CleanName("AB"), "AB", "name: private-use characters go");
        t.Equal(AuthWire.CleanName("   "), "", "name: only spaces leaves nothing");
        var twoByte = new string('é', 40);
        t.Equal(Encoding.UTF8.GetByteCount(AuthWire.CleanName(twoByte)), 64, "name: cut at 64 bytes (2-byte characters)");
        var fourByte = string.Concat(Enumerable.Repeat("\U0001F600", 20));
        var cutFour = AuthWire.CleanName(fourByte);
        t.Equal(Encoding.UTF8.GetByteCount(cutFour), 64, "name: cut at 64 bytes without splitting a 4-byte character");
        t.Equal(AuthWire.CleanName(new string('x', 63) + " yy"), new string('x', 63), "name: a space left at the cut is trimmed");

        var list = new List<AuthExtension> { new AuthExtension(0x7F, new byte[] { 1, 2, 3 }), new AuthExtension(0x01, Array.Empty<byte>()) };
        var enc = AuthWire.EncodeExtensions(list);
        t.Same(enc, new byte[] { 0x7F, 0, 3, 1, 2, 3, 0x01, 0, 0 }, "extensions encode as type, length, value");
        var back = AuthWire.DecodeExtensions(enc);
        t.Check(back.Count == 2 && back[0].Type == 0x7F && Wire.SameBytes(back[0].Value, new byte[] { 1, 2, 3 }) && back[1].Type == 1,
            "extensions decode, unknown types kept");
        t.Throws(AuthError.Malformed, () => AuthWire.DecodeExtensions(new byte[] { 0x7F, 0, 9, 1 }), "an extension that runs past the block is malformed");
        t.Throws(AuthError.Malformed, () => AuthWire.DecodeExtensions(new byte[] { 0x7F, 0 }), "a truncated extension header is malformed");
    }

    // MARK: vectors

    private static void Vectors(TestRun t, JsonElement v)
    {
        var hostKeyJson = v.GetProperty("hostIdentity");
        var deviceKeyJson = v.GetProperty("deviceKey");
        var hostPub = H(hostKeyJson, "public");
        var devicePub = H(deviceKeyJson, "public");
        using var hostKey = TestKey.FromVector(H(hostKeyJson, "private"), hostPub);
        using var deviceKey = TestKey.FromVector(H(deviceKeyJson, "private"), devicePub);

        t.Equal(DeviceIdentity.Id(hostPub), S(v, "hostId"), "host id");
        t.Equal(DeviceIdentity.FingerprintOfKey(hostPub), S(v, "hostFingerprint"), "host fingerprint");
        t.Equal(DeviceIdentity.Id(devicePub), S(v, "deviceId"), "device id");
        t.Equal(DeviceIdentity.FingerprintOfKey(devicePub), S(v, "deviceFingerprint"), "device fingerprint");
        foreach (var name in new[] { "hostIdentity", "deviceKey", "hostEphemeral", "clientEphemeral" })
        {
            t.Check(DeviceIdentity.IsValidPublicKey(H(v.GetProperty(name), "public")), $"{name} is a valid public key");
        }

        var hostEph = v.GetProperty("hostEphemeral");
        var clientEph = v.GetProperty("clientEphemeral");
        var ext = new AuthExtension((byte)v.GetProperty("responseExtension").GetProperty("type").GetInt32(),
            H(v.GetProperty("responseExtension"), "value"));
        uint hostCaps = v.GetProperty("hostCaps").GetUInt32();
        uint clientCaps = v.GetProperty("clientCaps").GetUInt32();
        var challenge = H(v, "challenge");

        var host = new HostHandshake(hostPub, hostCaps, S(v, "hostName"),
            ephemeral: EphemeralKey.FromPrivate(H(hostEph, "private"), H(hostEph, "public")),
            nonce: H(v, "hostNonce"));
        t.Same(host.Challenge.Payload, challenge, "the host builds the vector's challenge");

        var decoded = AuthChallenge.Decode(challenge);
        t.Equal(decoded.Hello.Capabilities, hostCaps, "challenge capabilities");
        t.Equal(decoded.Hello.DisplayName, S(v, "hostName"), "challenge host name");

        var client = new ClientHandshake(challenge, devicePub, clientCaps, S(v, "deviceName"), deviceKey.Signer,
            new[] { ext },
            EphemeralKey.FromPrivate(H(clientEph, "private"), H(clientEph, "public")),
            H(v, "clientNonce"));
        var response = client.Response;
        var vectorResponse = H(v, "response");
        var body = H(v, "responseBody");
        t.Same(Wire.Slice(response, 0, response.Length - 64), body, "the client builds the vector's response body");
        t.Equal(response.Length, vectorResponse.Length, "response length");
        t.Same(AuthWire.ClientSignatureInput(challenge, body), H(v, "clientSignatureInput"), "client signature input");
        t.Check(AuthSignature.Verify(Wire.Slice(response, response.Length - 64, 64), H(v, "clientSignatureInput"), devicePub),
            "the client's own signature verifies (signatures are random, so they are checked, not compared)");
        t.Check(AuthSignature.Verify(H(v, "clientSignature"), H(v, "clientSignatureInput"), devicePub),
            "the vector's client signature verifies");

        var verified = host.Verify(vectorResponse);
        t.Equal(verified.Id, S(v, "deviceId"), "host verifies the vector's response: device id");
        t.Equal(verified.Name, S(v, "deviceName"), "host verifies the vector's response: name");
        t.Equal(verified.Capabilities, clientCaps, "host verifies the vector's response: capabilities");
        t.Check(verified.Extensions.Count == 1 && verified.Extensions[0].Type == ext.Type, "the unknown extension is carried, to be skipped");
        var verifiedOwn = host.Verify(response);
        t.Equal(verifiedOwn.Id, S(v, "deviceId"), "host verifies the C# client's own response");

        t.Same(AuthWire.TranscriptHash(challenge, vectorResponse), H(v, "transcriptHash"), "transcript hash");
        var hostEphemeralKey = EphemeralKey.FromPrivate(H(hostEph, "private"), H(hostEph, "public"));
        t.Same(hostEphemeralKey.DeriveSecret(H(clientEph, "public")), H(v, "sharedSecret"), "ECDH shared secret");

        var results = v.GetProperty("results");
        foreach (var name in new[] { "accepted", "pending", "busy" })
        {
            var r = results.GetProperty(name);
            var status = (AuthStatus)r.GetProperty("status").GetInt32();
            var resultBody = H(r, "body");
            t.Same(AuthResult.MakeBody(status), resultBody, $"{name}: result body");
            var covered = AuthStatusInfo.SignsEmptyResponse(status) ? Array.Empty<byte>() : vectorResponse;
            var input = AuthWire.HostSignatureInput(challenge, covered, resultBody);
            t.Same(input, H(r, "signatureInput"), $"{name}: host signature input");
            t.Check(AuthSignature.Verify(H(r, "signature"), input, hostPub), $"{name}: the vector's host signature verifies");
            var mine = host.Result(status, vectorResponse, hostKey.Signer);
            t.Same(Wire.Slice(mine, 0, mine.Length - 64), resultBody, $"{name}: the C# host's result body");
            t.Check(AuthSignature.Verify(Wire.Slice(mine, mine.Length - 64, 64), input, hostPub), $"{name}: the C# host's signature verifies");
            var decodedResult = AuthResult.Decode(H(r, "payload"));
            t.Equal(decodedResult.Status, status, $"{name}: the vector's AUTH_RESULT payload decodes to its status");
            t.Same(decodedResult.Body, resultBody, $"{name}: the payload's body is the vector's body");
            t.Check(AuthSignature.Verify(decodedResult.Signature, input, hostPub), $"{name}: the payload's signature verifies");
        }

        var hostKeys = host.DeriveSessionKeys(verified);
        t.Same(hostKeys.HostToClient, H(v, "keyHostToClient"), "host-to-client key from the vector's response");
        t.Same(hostKeys.ClientToHost, H(v, "keyClientToHost"), "client-to-host key from the vector's response");
        t.Same(hostKeys.TranscriptHash, H(v, "transcriptHash"), "session keys carry the transcript hash");
        // The C# client signs afresh, so its transcript differs; it must still agree with a host that read its response.
        var clientKeys = client.DeriveSessionKeys();
        var ownHostKeys = host.DeriveSessionKeys(verifiedOwn);
        t.Same(clientKeys.HostToClient, ownHostKeys.HostToClient, "the C# client and host agree on the host-to-client key");
        t.Same(clientKeys.ClientToHost, ownHostKeys.ClientToHost, "the C# client and host agree on the client-to-host key");

        var hostToClient = new SecureSealer(hostKeys.HostToClient);
        var clientToHost = new SecureSealer(hostKeys.ClientToHost);
        var openFromHost = new SecureOpener(hostKeys.HostToClient);
        var openFromClient = new SecureOpener(hostKeys.ClientToHost);
        foreach (var f in v.GetProperty("secure").EnumerateArray())
        {
            bool toClient = S(f, "direction") == "hostToClient";
            ulong counter = f.GetProperty("counter").GetUInt64();
            var inner = H(f, "inner");
            var frame = H(f, "frame");
            var label = $"{S(f, "direction")} #{counter}";
            t.Same(SecureFrame.Nonce(counter), H(f, "nonce"), $"{label}: nonce");
            var sealer = toClient ? hostToClient : clientToHost;
            t.Equal(sealer.Counter, counter, $"{label}: sealer counter");
            t.Same(sealer.SealMessage(inner), frame, $"{label}: sealed frame");
            var opener = toClient ? openFromHost : openFromClient;
            var opened = opener.Open(Wire.Slice(frame, 5, frame.Length - 5));
            t.Check(opened.Type == inner[0] && Wire.SameBytes(opened.Payload, Wire.Slice(inner, 5, inner.Length - 5)),
                $"{label}: opened");
        }
    }

    // MARK: random-key handshakes

    private sealed class Pair : IDisposable
    {
        public TestKey HostKey = TestKey.Random();
        public TestKey DeviceKey = TestKey.Random();
        public HostHandshake Host;
        public ClientHandshake Client;

        public Pair(uint hostCaps = Caps.DeviceApproval, uint clientCaps = 0)
        {
            Host = new HostHandshake(HostKey.Public, hostCaps, "Test Mac");
            Client = new ClientHandshake(Host.Challenge.Payload, DeviceKey.Public, clientCaps, "Test PC", DeviceKey.Signer);
        }

        public void Dispose() { HostKey.Dispose(); DeviceKey.Dispose(); }
    }

    private static void HandshakePerStatus(TestRun t)
    {
        foreach (AuthStatus status in Enum.GetValues(typeof(AuthStatus)))
        {
            using var p = new Pair();
            var device = p.Host.Verify(p.Client.Response);
            t.Equal(device.Id, DeviceIdentity.Id(p.DeviceKey.Public), $"{status}: the host learns the device id");
            t.Equal(device.Name, "Test PC", $"{status}: the host learns the device name");
            var result = p.Host.Result(status, p.Client.Response, p.HostKey.Signer);
            t.Equal(p.Client.StatusOfResult(result), status, $"{status}: the client verifies the result");

            // The same result with its status byte changed must not verify.
            var changed = (byte[])result.Clone();
            changed[0] = (byte)(status == AuthStatus.Accepted ? AuthStatus.Pending : AuthStatus.Accepted);
            t.Throws(AuthError.BadSignature, () => p.Client.StatusOfResult(changed), $"{status}: a changed status byte does not verify");
            var flipped = (byte[])result.Clone();
            flipped[flipped.Length - 1] ^= 1;
            t.Throws(AuthError.BadSignature, () => p.Client.StatusOfResult(flipped), $"{status}: a changed signature does not verify");

            if (AuthStatusInfo.SignsEmptyResponse(status))
            {
                // Signed over an empty response: still verifies for a host that never saw one.
                var blind = p.Host.Result(status, Array.Empty<byte>(), p.HostKey.Signer);
                t.Equal(p.Client.StatusOfResult(blind), status, $"{status}: signed with an empty response, as the host does before it has read one");
            }
            else
            {
                var blind = p.Host.Result(status, Array.Empty<byte>(), p.HostKey.Signer);
                t.Throws(AuthError.BadSignature, () => p.Client.StatusOfResult(blind), $"{status}: signed over another response does not verify");
            }

            if (status == AuthStatus.Accepted)
            {
                var hostKeys = p.Host.DeriveSessionKeys(device);
                var clientKeys = p.Client.DeriveSessionKeys();
                t.Same(hostKeys.HostToClient, clientKeys.HostToClient, "accepted: both sides derive the host-to-client key");
                t.Same(hostKeys.ClientToHost, clientKeys.ClientToHost, "accepted: both sides derive the client-to-host key");
                t.Check(!Wire.SameBytes(hostKeys.HostToClient, hostKeys.ClientToHost), "accepted: the two directions use different keys");
            }
        }

        using (var p = new Pair())
        {
            t.Throws(AuthError.Malformed, () => AuthResult.Decode(new byte[] { 9, 0, 0 }), "a result with an unknown status is malformed");
            t.Throws(AuthError.Malformed, () => p.Client.StatusOfResult(new byte[10]), "a short result is malformed");
        }
    }

    private static void HostRefuses(TestRun t)
    {
        using var p = new Pair();
        var good = p.Client.Response;

        var bit = (byte[])good.Clone();
        bit[bit.Length - 1] ^= 1;
        t.Throws(AuthError.BadSignature, () => p.Host.Verify(bit), "a changed signature is refused");

        var nameChanged = (byte[])good.Clone();
        nameChanged[1 + 4 + 32 + 65 + 65 + 1] ^= 1;
        t.Throws(AuthError.BadSignature, () => p.Host.Verify(nameChanged), "a changed name is refused");

        var version = (byte[])good.Clone();
        version[0] = 2;
        t.Throws(AuthError.UnsupportedVersion, () => p.Host.Verify(version), "another version is refused");

        t.Throws(AuthError.Malformed, () => p.Host.Verify(Wire.Slice(good, 0, good.Length - 1)), "a truncated response is refused");
        t.Throws(AuthError.Malformed, () => p.Host.Verify(Wire.Concat(good, new byte[] { 0 })), "a response with a byte too many is refused");
        t.Throws(AuthError.Malformed, () => p.Host.Verify(new byte[AuthWire.MaxResponseBytes + 1]), "a response over 4096 bytes is refused");
        t.Throws(AuthError.Malformed, () => p.Host.Verify(Array.Empty<byte>()), "an empty response is refused");

        // An identity key that is not on the curve.
        var offCurve = (byte[])good.Clone();
        int identityAt = 1 + 4 + 32 + 65;
        offCurve[identityAt + 64] ^= 1;
        t.Throws(AuthError.InvalidKey, () => p.Host.Verify(offCurve), "an identity key off the curve is refused");
        var ephOff = (byte[])good.Clone();
        ephOff[1 + 4 + 32 + 64] ^= 1;
        t.Throws(AuthError.InvalidKey, () => p.Host.Verify(ephOff), "an ephemeral key off the curve is refused");

        // A response built for another challenge does not verify against this one.
        using var other = new Pair();
        t.Throws(AuthError.BadSignature, () => p.Host.Verify(other.Client.Response), "a response to another challenge is refused (replay)");

        // A different key signing a response that shows this device's key.
        using var stranger = TestKey.Random();
        var forged = new ClientHandshake(p.Host.Challenge.Payload, p.DeviceKey.Public, 0, "Test PC", stranger.Signer);
        t.Throws(AuthError.BadSignature, () => p.Host.Verify(forged.Response), "a response signed by another key is refused");

        t.Throws(AuthError.InvalidKey, () => new HostHandshake(new byte[65], 0, "x"), "a host will not start with an invalid identity key");
    }

    private static void ClientRefuses(TestRun t)
    {
        using var p = new Pair();
        var ch = p.Host.Challenge.Payload;
        using var dev = TestKey.Random();

        var v2 = (byte[])ch.Clone();
        v2[0] = 2;
        t.Throws(AuthError.UnsupportedVersion, () => new ClientHandshake(v2, dev.Public, 0, "x", dev.Signer), "a challenge of another version is refused");

        var trailing = Wire.Concat(ch, new byte[] { 0 });
        t.Throws(AuthError.Malformed, () => new ClientHandshake(trailing, dev.Public, 0, "x", dev.Signer), "a challenge with a byte too many is refused");
        t.Throws(AuthError.Malformed, () => new ClientHandshake(Wire.Slice(ch, 0, ch.Length - 1), dev.Public, 0, "x", dev.Signer), "a truncated challenge is refused");

        var badIdentity = (byte[])ch.Clone();
        badIdentity[1 + 4 + 32 + 65 + 64] ^= 1;
        t.Throws(AuthError.InvalidKey, () => new ClientHandshake(badIdentity, dev.Public, 0, "x", dev.Signer), "a host key off the curve is refused");
        var badEphemeral = (byte[])ch.Clone();
        badEphemeral[1 + 4 + 32 + 64] ^= 1;
        t.Throws(AuthError.InvalidKey, () => new ClientHandshake(badEphemeral, dev.Public, 0, "x", dev.Signer), "a host ephemeral key off the curve is refused");
        t.Throws(AuthError.InvalidKey, () => new ClientHandshake(ch, new byte[65], 0, "x", dev.Signer), "an invalid device key is refused");
        t.Throws(AuthError.BadSignature, () => new ClientHandshake(ch, dev.Public, 0, "x", _ => new byte[10]), "a signer that returns a short signature is refused");

        // A result from a host with another key does not verify, whatever it says.
        using var impostor = TestKey.Random();
        var fake = p.Host.Result(AuthStatus.Accepted, p.Client.Response, impostor.Signer);
        t.Throws(AuthError.BadSignature, () => p.Client.StatusOfResult(fake), "a result signed by another key is refused");

        // A result for another response (another connection) does not verify.
        using var q = new Pair();
        var otherResult = q.Host.Result(AuthStatus.Accepted, q.Client.Response, q.HostKey.Signer);
        t.Throws(AuthError.BadSignature, () => p.Client.StatusOfResult(otherResult), "a result from another connection is refused");
    }

    // MARK: SECURE

    private static byte[] Message(byte type, byte[] payload) => Wire.Frame(type, payload);

    private static byte[] RawSeal(byte[] key, ulong counter, byte[] inner)
    {
        var ct = new byte[inner.Length];
        var tag = new byte[16];
        using var aes = new AesGcm(key, 16);
        aes.Encrypt(SecureFrame.Nonce(counter), inner, ct, tag);
        return Wire.Concat(ct, tag);
    }

    private static void SecureFrames(TestRun t)
    {
        var key = AuthWire.RandomBytes(32);
        var sealer = new SecureSealer(key);
        var opener = new SecureOpener(key);
        var m0 = Message(WireType.Hello, new byte[] { 1, 1 });
        var m1 = Message(0x20, new byte[] { 9, 9, 9 });
        var m2 = Message(0x22, new byte[] { 1 });

        var s0 = sealer.Seal(m0);
        var s1 = sealer.Seal(m1);
        var s2 = sealer.Seal(m2);
        t.Equal(sealer.Counter, 3UL, "the counter goes up by one per message");
        t.Check(s0.Length == m0.Length + 16, "a sealed message is the message plus a 16-byte tag");

        var o0 = opener.Open(s0);
        t.Check(o0.Type == WireType.Hello && Wire.SameBytes(o0.Payload, new byte[] { 1, 1 }), "in order: first message opens");
        var o1 = opener.Open(s1);
        t.Check(o1.Type == 0x20 && o1.Payload.Length == 3, "in order: second message opens");

        // A frame that was already opened (replay): the counter has moved on.
        t.Throws(AuthError.DecryptFailed, () => opener.Open(s1), "a replayed frame is refused");
        t.Equal(opener.Counter, 2UL, "a refused frame does not move the counter");
        // The next one in order still opens, so a refusal did not break the stream (the connection is closed by the caller anyway).
        var o2 = opener.Open(s2);
        t.Check(o2.Type == 0x22, "the next frame in order opens");

        // Reordered: the third before the second.
        var op2 = new SecureOpener(key);
        op2.Open(s0);
        t.Throws(AuthError.DecryptFailed, () => op2.Open(s2), "a reordered frame is refused");

        // Tampered.
        var op3 = new SecureOpener(key);
        var tampered = (byte[])s0.Clone();
        tampered[0] ^= 1;
        t.Throws(AuthError.DecryptFailed, () => op3.Open(tampered), "a changed ciphertext byte is refused");
        var tagFlip = (byte[])s0.Clone();
        tagFlip[tagFlip.Length - 1] ^= 1;
        t.Throws(AuthError.DecryptFailed, () => op3.Open(tagFlip), "a changed tag byte is refused");
        t.Throws(AuthError.DecryptFailed, () => op3.Open(new byte[15]), "a payload shorter than the tag is refused");
        t.Throws(AuthError.DecryptFailed, () => new SecureOpener(AuthWire.RandomBytes(32)).Open(s0), "the wrong key is refused");

        // Truncated and extended.
        t.Throws(AuthError.DecryptFailed, () => new SecureOpener(key).Open(Wire.Slice(s0, 0, s0.Length - 1)), "a truncated payload is refused");
        t.Throws(AuthError.DecryptFailed, () => new SecureOpener(key).Open(Wire.Concat(s0, new byte[1])), "an extended payload is refused");

        // Inner messages that may not travel inside SECURE.
        foreach (var type in new byte[] { WireType.Secure, WireType.AuthChallenge, WireType.AuthResponse, WireType.AuthResult })
        {
            var forbidden = Message(type, new byte[] { 1 });
            t.Throws(AuthError.ForbiddenInnerMessage, () => new SecureSealer(key).Seal(forbidden), $"sealing type 0x{type:X2} is refused");
            t.Throws(AuthError.ForbiddenInnerMessage, () => new SecureOpener(key).Open(RawSeal(key, 0, forbidden)), $"opening type 0x{type:X2} is refused");
        }
        t.Throws(AuthError.ForbiddenInnerMessage, () => new SecureSealer(key).Seal(new byte[] { 1, 0, 0, 0, 5, 1 }), "sealing a message whose length field is wrong is refused");
        t.Throws(AuthError.ForbiddenInnerMessage, () => new SecureSealer(key).Seal(new byte[3]), "sealing less than a header is refused");
        t.Throws(AuthError.Malformed, () => new SecureOpener(key).Open(RawSeal(key, 0, new byte[] { 1, 0, 0, 0, 5, 1 })), "opening a message whose length field is wrong is malformed");
        t.Throws(AuthError.Malformed, () => new SecureOpener(key).Open(RawSeal(key, 0, new byte[3])), "opening less than a header is malformed");

        // The counter limit.
        t.Throws(AuthError.CounterExhausted, () => new SecureSealer(key, AuthWire.CounterLimit).Seal(m0), "a sealer at the counter limit stops");
        t.Throws(AuthError.CounterExhausted, () => new SecureOpener(key, AuthWire.CounterLimit).Open(s0), "an opener at the counter limit stops");
        var last = new SecureSealer(key, AuthWire.CounterLimit - 1);
        last.Seal(m0);
        t.Throws(AuthError.CounterExhausted, () => last.Seal(m0), "the last counter value is used once, then it stops");

        t.Same(SecureFrame.Nonce(1), new byte[] { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, "nonce: 4 zero bytes then the counter, big-endian");
        t.Same(sealer.SealMessage(m0).AsSpan(0, 5).ToArray(), new byte[] { WireType.Secure, 0, 0, 0, (byte)(m0.Length + 16) }, "a SECURE message is framed with type 0x0F");
    }
}
