namespace Clamshell;

// What `decode-audio-file` needs around AudioDecoder: reading an ADTS file and
// judging the PCM that comes out. Pure code, so `selftest` checks it too.

/// <summary>Splits an ADTS file (what `ffmpeg -f adts` writes) into the raw
/// access units AUDIO_FRAME carries: the header of each frame is dropped.</summary>
internal static class Adts
{
    /// <summary>The access units, in order. `problem` says why the file stopped
    /// early (or is not AAC-LC 48 kHz stereo); null when every byte was used.</summary>
    public static List<byte[]> Split(byte[] d, out string? problem)
    {
        var units = new List<byte[]>();
        problem = null;
        int i = 0;
        while (i < d.Length)
        {
            if (i + 7 > d.Length) { problem = $"{d.Length - i} bytes of a frame header left at byte {i}"; break; }
            if (d[i] != 0xFF || (d[i + 1] & 0xF0) != 0xF0) { problem = $"no ADTS sync word at byte {i}"; break; }
            bool hasCrc = (d[i + 1] & 1) == 0;
            int profile = (d[i + 2] >> 6) & 3;          // 1 = AAC-LC
            int rateIndex = (d[i + 2] >> 2) & 15;       // 3 = 48000 Hz
            int channels = ((d[i + 2] & 1) << 2) | (d[i + 3] >> 6);
            int length = ((d[i + 3] & 3) << 11) | (d[i + 4] << 3) | (d[i + 5] >> 5);
            int header = hasCrc ? 9 : 7;
            if (profile != 1 || rateIndex != 3 || channels != 2)
            {
                problem = $"not AAC-LC 48 kHz stereo (profile {profile}, rate index {rateIndex}, channels {channels})";
                break;
            }
            if (length < header || i + length > d.Length) { problem = $"bad frame length {length} at byte {i}"; break; }
            units.Add(d.AsSpan(i + header, length - header).ToArray());
            i += length;
        }
        return units;
    }
}

/// <summary>Checks decoded PCM: length and the pitch of a test tone.</summary>
internal static class AudioCheck
{
    /// <summary>The share (0..1) of a signal's energy that sits at `hz`. A pure
    /// tone gives about 1, silence or another pitch gives about 0 (Goertzel).</summary>
    public static double ToneFraction(ReadOnlySpan<short> x, double hz, int rate)
    {
        if (x.IsEmpty) return 0;
        double coeff = 2 * Math.Cos(2 * Math.PI * hz / rate);
        double s1 = 0, s2 = 0, energy = 0;
        foreach (short v in x)
        {
            double s = v + coeff * s1 - s2;
            s2 = s1; s1 = s;
            energy += (double)v * v;
        }
        if (energy <= 0) return 0;
        double power = s1 * s1 + s2 * s2 - coeff * s1 * s2;
        return 2 * power / (x.Length * energy);
    }

    /// <summary>True when `pcm` (16-bit stereo, 48 kHz) is `units` decoded access
    /// units long, within one frame of 1024, lasts about `seconds`, and both
    /// channels carry a `hz` tone. `detail` says what was seen either way.</summary>
    public static bool Verify(byte[] pcm, int units, double hz, double seconds, out string detail)
    {
        if (pcm.Length % AudioDecoder.BytesPerFrame != 0)
        {
            detail = $"PCM is {pcm.Length} bytes, not a whole number of stereo frames";
            return false;
        }
        int frames = pcm.Length / AudioDecoder.BytesPerFrame;
        int expected = units * AudioDecoder.FramesPerUnit;
        if (Math.Abs(frames - expected) > AudioDecoder.FramesPerUnit)
        {
            detail = $"decoded {frames} frames from {units} access units, expected {expected} (within {AudioDecoder.FramesPerUnit})";
            return false;
        }
        // About the clip's length: an encoder adds a frame or two of priming and padding.
        int wanted = (int)(seconds * AudioDecoder.SampleRate);
        if (Math.Abs(frames - wanted) > 3 * AudioDecoder.FramesPerUnit)
        {
            detail = $"decoded {frames} frames, a {seconds} s clip should be about {wanted}";
            return false;
        }

        // The ends hold the codec's priming and padding: leave them out.
        int skip = 4 * AudioDecoder.FramesPerUnit;
        if (frames <= 2 * skip) { detail = $"only {frames} frames, too short to check a tone"; return false; }
        int n = frames - 2 * skip;
        var left = new short[n];
        var right = new short[n];
        for (int i = 0; i < n; i++)
        {
            int o = (skip + i) * AudioDecoder.BytesPerFrame;
            left[i] = BitConverter.ToInt16(pcm, o);
            right[i] = BitConverter.ToInt16(pcm, o + 2);
        }
        double l = ToneFraction(left, hz, AudioDecoder.SampleRate);
        double r = ToneFraction(right, hz, AudioDecoder.SampleRate);
        detail = $"{frames} frames from {units} access units; {hz} Hz holds {l:P0} of the left and {r:P0} of the right channel";
        return l > 0.8 && r > 0.8;
    }
}
