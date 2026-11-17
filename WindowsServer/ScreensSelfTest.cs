using System.Drawing;
using System.Windows.Forms;
using Clamshell.Auth;

namespace Clamshell;

// `ClamshellServer selftest-screens`: builds each device window once with no network and no
// real device: the approval window, the Devices panel and the Settings window (with and
// without a device list). It checks that every control has its text, lies inside its window and
// has room for its text, and that the approval buttons start switched off. Made-up devices,
// throwaway key and list.
internal static class ScreensSelfTest
{
    private static int _failures;

    private static void Check(bool ok, string what)
    {
        Console.Error.WriteLine($"screens-selftest: {(ok ? "ok  " : "FAIL")} {what}");
        if (!ok) _failures++;
    }

    /// <summary>True if the text of a label fits its box, wrapping at the box's width.</summary>
    private static bool TextFits(Label l)
    {
        if (l.Text.Length == 0) return true;
        var size = TextRenderer.MeasureText(l.Text, l.Font, new Size(l.Width, int.MaxValue),
            TextFormatFlags.WordBreak | TextFormatFlags.NoPadding);
        return size.Height <= l.Height;
    }

    private static void CheckLayout(string window, IEnumerable<Control> parts, Rectangle inside)
    {
        foreach (var c in parts)
        {
            Check(inside.Contains(c.Bounds), $"{window}: {Describe(c)} lies inside the window");
            if (c is Label l) Check(TextFits(l), $"{window}: {Describe(c)} has room for its text");
            if (c is Button b) Check(b.Text.Length > 0, $"{window}: {Describe(c)} has a name");
        }
    }

    private static string Describe(Control c) =>
        c.GetType().Name + (c.Text.Length > 0 ? $" \"{(c.Text.Length > 24 ? c.Text[..24] + "..." : c.Text)}\"" : "");

    public static int Run()
    {
        var folder = Path.Combine(Path.GetTempPath(), "clamshell-screens-selftest-" + Guid.NewGuid().ToString("N"));
        var keyName = "Clamshell.Host.ScreensSelfTest." + Guid.NewGuid().ToString("N");
        HostIdentity? identity = null;
        HostAuth? auth = null;
        try
        {
            identity = HostIdentity.Open(keyName);
            auth = new HostAuth(folder, identity, requireApproval: true, watch: false);

            using var waitingKey = new MemoryDeviceKey();
            using var trustedKey = new MemoryDeviceKey();
            using var deniedKey = new MemoryDeviceKey();
            var a = auth.Store.Ask(waitingKey.PublicKey, "Example Phone", "203.0.113.7", null, _ => true);
            var b = auth.Store.Ask(trustedKey.PublicKey, "Example Tablet", "198.51.100.4", null, _ => false);
            var c = auth.Store.Ask(deniedKey.PublicKey, "Example Laptop", "192.0.2.9", null, _ => false);
            Check(a == DeviceTrustStore.Answer.Waiting && b == DeviceTrustStore.Answer.Waiting && c == DeviceTrustStore.Answer.Waiting,
                "three made-up devices were put on the list as waiting");
            auth.Store.Decide(DeviceIdentity.Id(trustedKey.PublicKey), DeviceTrustStore.Decision.Approve, DeviceTrustStore.DecidedOnHost, true);
            auth.Store.Decide(DeviceIdentity.Id(deniedKey.PublicKey), DeviceTrustStore.Decision.Deny, DeviceTrustStore.DecidedOnHost, true);

            // The approval window.
            var waiting = auth.Store.Waiting();
            Check(waiting.Count == 1, "one device is waiting");
            using (var form = new ApprovalForm())
            {
                form.Ask(waiting[0], 1, 3, connectedNow: true, nameIsTaken: true, DeviceText.Now());
                _ = form.Handle;
                Check(form.AskingId == waiting[0].Id, "approval window: it asks about the waiting device");
                Check(!form.ButtonsEnabled, "approval window: both buttons start switched off");
                Check(form.AcceptButton == null && form.CancelButton == null, "approval window: no default button");
                Check(form.Parts.OfType<Label>().Any(l => l.Text == waiting[0].Fingerprint), "approval window: shows the fingerprint");
                Check(form.Parts.OfType<Label>().Any(l => l.Text == waiting[0].Label), "approval window: shows the name");
                CheckLayout("approval window", form.Parts, form.ClientRectangle);
                form.DismissQuietly();
                Check(form.AskingId == null, "approval window: dismissing it asks about nothing");
            }

            // The Devices section.
            using (var panel = new DevicesPanel(auth))
            {
                _ = panel.Handle;
                Check(panel.Rows == 3, "devices panel: lists the three devices");
                CheckLayout("devices panel", panel.Parts, panel.ClientRectangle);
            }

            // Settings, with a device list and without.
            using (var settings = new SettingsForm(5903, _ => { }, new UpdateChecker(), auth))
            {
                _ = settings.Handle;
                var top = settings.Controls.Cast<Control>().ToList();
                CheckLayout("settings", top, settings.ClientRectangle);
                var group = top.OfType<GroupBox>().FirstOrDefault();
                Check(group != null && group.Controls.OfType<DevicesPanel>().Any(), "settings: has the Devices section");
            }
            using (var settings = new SettingsForm(5903, _ => { }, new UpdateChecker(), null))
            {
                _ = settings.Handle;
                var group = settings.Controls.OfType<GroupBox>().FirstOrDefault();
                var note = group?.Controls.OfType<Label>().FirstOrDefault();
                Check(note != null && note.Text.Contains("nothing is being served"), "settings without a device list: says nothing is served");
                if (note != null) Check(TextFits(note), "settings without a device list: the note has room for its text");
            }
        }
        catch (Exception e)
        {
            Check(false, "a screen could not be built: " + e);
        }
        finally
        {
            try { auth?.Dispose(); } catch (Exception) { }
            try { identity?.DeleteFromStore(); } catch (Exception) { }
            identity?.Dispose();
            try { Directory.Delete(folder, true); } catch (Exception) { }
        }
        Console.Error.WriteLine($"screens-selftest: {(_failures == 0 ? "all checks passed" : _failures + " failed")}");
        return _failures == 0 ? 0 : 1;
    }
}
