using System.Net.Http;
using System.Net.Http.Headers;
using System.Text.Json;

namespace Clamshell;

// Mirrors checkForUpdate() in the Mac app's StatusBarApp.swift: compare the
// running version against the latest GitHub release tag, numerically. Unlike
// the Mac side (UpdateInstaller.swift), this does NOT download and swap the
// binary in place — Windows can't overwrite a running exe, and re-deriving
// the mac's codesign-verify-and-swap dance for an installer-based app isn't
// worth it. This just tells the user an update exists and hands them the
// release page.
internal sealed class UpdateChecker
{
    private const string LatestReleaseApi = "https://api.github.com/repos/frindle/clamshell/releases/latest";

    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(10) };

    private readonly Version _current;

    public UpdateChecker()
    {
        _current = typeof(UpdateChecker).Assembly.GetName().Version ?? new Version(0, 0, 0);
    }

    /// <summary>Checks once; invokes <paramref name="onUpdateFound"/> with
    /// (tag, release page URL) if the latest release is newer than this
    /// build. Never throws — logs and returns on any failure.</summary>
    public async Task CheckOnceAsync(Action<string, string> onUpdateFound)
    {
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, LatestReleaseApi);
            // GitHub's API 403s anonymous requests with no User-Agent.
            req.Headers.UserAgent.Add(new ProductInfoHeaderValue("Clamshell-Windows-Host", "1.0"));
            using var resp = await Http.SendAsync(req);
            if (!resp.IsSuccessStatusCode) return;

            using var stream = await resp.Content.ReadAsStreamAsync();
            using var doc = await JsonDocument.ParseAsync(stream);
            var root = doc.RootElement;
            if (!root.TryGetProperty("tag_name", out var tagProp) || tagProp.GetString() is not { } tag) return;
            if (!root.TryGetProperty("html_url", out var urlProp) || urlProp.GetString() is not { } htmlUrl) return;

            var latestStr = tag.StartsWith('v') ? tag[1..] : tag;
            if (!Version.TryParse(latestStr, out var latest)) return;
            if (latest <= _current) return;

            Log.Line($"update available: {tag} (running {_current})");
            onUpdateFound(tag, htmlUrl);
        }
        catch (Exception e) { Log.Line($"update check failed: {e.Message}"); }
    }
}
