using System.Security.Cryptography;

namespace Clamshell.Auth;

/// <summary>A tiny test runner: counts passes and failures, never stops at the
/// first failure, and writes one line per check through the log it is given.</summary>
public sealed class TestRun
{
    private readonly Action<string> _log;
    public int Passed { get; private set; }
    public int Failed { get; private set; }

    public TestRun(Action<string> log) { _log = log; }

    public void Check(bool ok, string name)
    {
        if (ok) { Passed++; _log($"  ok   {name}"); }
        else { Failed++; _log($"  FAIL {name}"); }
    }

    public void Same(byte[]? actual, byte[]? expected, string name)
    {
        bool ok = Wire.SameBytes(actual, expected);
        Check(ok, name);
        if (!ok)
        {
            _log($"       expected {(expected is null ? "null" : Hex.Encode(expected))}");
            _log($"       actual   {(actual is null ? "null" : Hex.Encode(actual))}");
        }
    }

    public void Equal<T>(T actual, T expected, string name)
    {
        bool ok = EqualityComparer<T>.Default.Equals(actual, expected);
        Check(ok, name);
        if (!ok) _log($"       expected {expected}, actual {actual}");
    }

    /// <summary>Passes when the action throws an AuthException with this error.</summary>
    public void Throws(AuthError expected, Action action, string name)
    {
        try
        {
            action();
            Check(false, name + " (nothing was thrown)");
        }
        catch (AuthException e)
        {
            Check(e.Error == expected, e.Error == expected ? name : $"{name} (threw {e.Error}, wanted {expected})");
        }
        catch (Exception e)
        {
            Check(false, $"{name} (threw {e.GetType().Name}: {e.Message})");
        }
    }

    /// <summary>Runs a group; an exception that escapes it is one failure, and the
    /// next group still runs.</summary>
    public void Group(string name, Action body)
    {
        _log($"[{name}]");
        try { body(); }
        catch (Exception e)
        {
            Failed++;
            _log($"  FAIL {name}: {e.GetType().Name}: {e.Message}");
        }
    }
}

/// <summary>A signing key for tests: random, or fixed from a vector.</summary>
public sealed class TestKey : IDisposable
{
    private readonly ECDsa _key;
    public byte[] Public { get; }

    private TestKey(ECDsa key)
    {
        _key = key;
        Public = P256Util.ExportPublic(key.ExportParameters(false));
    }

    public static TestKey Random() => new TestKey(ECDsa.Create(ECCurve.NamedCurves.nistP256));

    public static TestKey FromVector(byte[] privateValue, byte[] publicKey)
    {
        var p = P256Util.PublicParameters(publicKey);
        p.D = privateValue;
        return new TestKey(ECDsa.Create(p));
    }

    public AuthSigner Signer => input => AuthSignature.Sign(_key, input);

    public void Dispose() => _key.Dispose();
}
