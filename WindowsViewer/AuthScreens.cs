using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Clamshell.Auth;

namespace Clamshell;

// The screens the device-auth flow asks for. Plain WPF, built in code, no
// styling beyond readable defaults: a separate design pass restyles everything
// later. Wording follows the iOS screens (bundle A4), with "this PC" for
// "this device"/"this app".
//
// Buttons: Answer(true/false) is the user's answer to a question the flow asked
// (Connect / Cancel). Stop ends the connection and leaves the window for the
// user to close (Cancel while waiting, Close on a screen with no way forward).
internal static class AuthScreens
{
    /// <summary>True for the states that take over the window.</summary>
    public static bool IsScreen(FlowState s) => s.Kind switch
    {
        FlowStateKind.WaitingForApproval or FlowStateKind.ConfirmHost or FlowStateKind.ChangedIdentity
            or FlowStateKind.DidNotIdentify or FlowStateKind.AskUnverified or FlowStateKind.Denied
            or FlowStateKind.Invalid or FlowStateKind.Busy or FlowStateKind.HostNeedsKeychain
            or FlowStateKind.RemoteAccessOff => true,
        _ => false,
    };

    public static string Title(FlowState s) => s.Kind switch
    {
        FlowStateKind.WaitingForApproval => "Waiting for approval",
        FlowStateKind.ConfirmHost => "Is this your Mac?",
        FlowStateKind.ChangedIdentity => "This Mac's identity has changed",
        FlowStateKind.DidNotIdentify => "This Mac did not identify itself",
        FlowStateKind.AskUnverified => "This Mac can't prove who it is",
        FlowStateKind.Denied => "This Mac turned this PC away",
        FlowStateKind.Invalid => "This Mac sent something this viewer cannot use",
        FlowStateKind.Busy => "The Mac is busy",
        FlowStateKind.HostNeedsKeychain => "The Mac needs Keychain approval",
        FlowStateKind.RemoteAccessOff => "Remote access is off",
        FlowStateKind.Connecting => "Connecting",
        FlowStateKind.Connected => "Connected",
        _ => "Could not connect",
    };

    public static string Body(FlowState s) => s.Kind switch
    {
        FlowStateKind.WaitingForApproval =>
            $"On {s.HostName}, open Clamshell in the menu bar and approve this PC. Check that the Mac shows the same fingerprint for it.",
        FlowStateKind.ConfirmHost =>
            $"{s.HostName} let this PC in without asking. Before you connect, check that this fingerprint matches the one under Devices in Clamshell's menu on the Mac.",
        FlowStateKind.ChangedIdentity =>
            $"The computer at {s.Address} is not the one this viewer saved. Clamshell may have been set up again on it, it may be a different computer, or someone may be in the way of the connection. Nothing was sent to it.",
        FlowStateKind.DidNotIdentify =>
            $"{s.HostName} has always proved who it is before, and this time it did not. Nothing was sent to it.",
        FlowStateKind.AskUnverified =>
            $"It may be running a version of Clamshell older than 0.12. Whatever you type goes to the computer that answers at {s.Address}. Connect anyway?",
        FlowStateKind.Denied =>
            $"It was denied or revoked on {s.HostName}. It can be allowed again under Devices in Clamshell's menu on the Mac.",
        FlowStateKind.Invalid =>
            $"{s.HostName} answered in a way this viewer does not accept. Nothing more was sent to it.",
        FlowStateKind.Busy => $"The Mac is busy. Trying again in {s.RetryIn} s.",
        FlowStateKind.HostNeedsKeychain =>
            $"The Mac needs Keychain approval for Clamshell before it can accept devices. Approve it on the Mac. Trying again in {s.RetryIn} s.",
        FlowStateKind.RemoteAccessOff =>
            $"Remote access is off on this Mac. Turn on Screen Sharing in System Settings > General > Sharing there. Trying again in {s.RetryIn} s.",
        FlowStateKind.Failed => s.Message,
        _ => "",
    };

    /// <summary>The value rows under the text, label first.</summary>
    public static List<string> Rows(FlowState s) => s.Kind switch
    {
        FlowStateKind.WaitingForApproval => new()
        {
            $"This PC: {s.DeviceName}, {s.DeviceFingerprint}",
            $"The Mac: {s.HostName}, {s.HostFingerprint}",
        },
        FlowStateKind.ConfirmHost => new() { s.HostFingerprint },
        FlowStateKind.ChangedIdentity => new()
        {
            $"Saved: {s.SavedFingerprint}",
            $"Now showing: {s.NowFingerprint}",
        },
        _ => new(),
    };

    /// <summary>Button labels in order. The first is the yes of a question.</summary>
    public static List<string> Buttons(FlowState s) => s.Kind switch
    {
        FlowStateKind.WaitingForApproval => new() { "Cancel" },
        FlowStateKind.ConfirmHost or FlowStateKind.AskUnverified => new() { "Connect", "Cancel" },
        FlowStateKind.ChangedIdentity or FlowStateKind.DidNotIdentify or FlowStateKind.Denied
            or FlowStateKind.Invalid => new() { "Close" },
        FlowStateKind.Busy or FlowStateKind.HostNeedsKeychain or FlowStateKind.RemoteAccessOff => new() { "Cancel" },
        _ => new(),
    };

    public static UIElement Build(FlowState s, Action<bool> answer, Action stop)
    {
        var panel = new StackPanel { Margin = new Thickness(24), MaxWidth = 560, VerticalAlignment = VerticalAlignment.Center };
        panel.Children.Add(new TextBlock
        {
            Text = Title(s), FontSize = 22, FontWeight = FontWeights.SemiBold,
            Margin = new Thickness(0, 0, 0, 12), TextWrapping = TextWrapping.Wrap,
        });
        var body = Body(s);
        if (body.Length > 0)
        {
            panel.Children.Add(new TextBlock { Text = body, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 12) });
        }
        foreach (var row in Rows(s))
        {
            panel.Children.Add(new TextBlock
            {
                Text = row, FontFamily = new FontFamily("Consolas"), TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 0, 0, 6),
            });
        }
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 12, 0, 0) };
        bool isQuestion = s.Kind is FlowStateKind.ConfirmHost or FlowStateKind.AskUnverified;
        var labels = Buttons(s);
        for (int i = 0; i < labels.Count; i++)
        {
            bool yes = isQuestion && i == 0;
            var b = new Button { Content = labels[i], MinWidth = 90, Margin = new Thickness(0, 0, 8, 0), Padding = new Thickness(10, 4, 10, 4) };
            if (isQuestion) b.Click += (_, _) => answer(yes);
            else b.Click += (_, _) => stop();
            buttons.Children.Add(b);
        }
        panel.Children.Add(buttons);
        return new Border
        {
            Background = new SolidColorBrush(Color.FromRgb(0xF4, 0xF4, 0xF4)),
            Child = new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto },
        };
    }

    /// <summary>The label that stays visible while a session runs without proof of who answers.</summary>
    public static UIElement BuildNotVerifiedBadge() => new Border
    {
        Background = new SolidColorBrush(Color.FromRgb(0xB0, 0x30, 0x20)),
        Padding = new Thickness(8, 2, 8, 2),
        HorizontalAlignment = HorizontalAlignment.Left,
        VerticalAlignment = VerticalAlignment.Top,
        Child = new TextBlock { Text = "Not verified", Foreground = Brushes.White },
    };

    /// <summary>Builds every screen once, with no network, and checks the wording
    /// and the buttons. Returns the number of failures.</summary>
    public static int SelfTest()
    {
        int failed = 0;
        void Check(bool ok, string what)
        {
            if (!ok) { failed++; Log.Line($"selftest-screens: FAIL {what}"); }
        }

        var states = new List<FlowState>
        {
            FlowState.WaitingForApproval("Studio", "AB12-CD34-EF56-7890", "OFFICE", "1111-2222-3333-4444"),
            FlowState.ConfirmHost("Studio", "AB12-CD34-EF56-7890"),
            FlowState.ChangedIdentity("studio.local:5903", "AB12-CD34-EF56-7890", "9999-8888-7777-6666"),
            FlowState.DidNotIdentify("Studio"),
            FlowState.AskUnverified("studio.local:5903"),
            FlowState.Denied("Studio"),
            FlowState.Invalid("Studio"),
            FlowState.Busy(15),
            FlowState.HostNeedsKeychain(15),
            FlowState.RemoteAccessOff(15),
        };
        int answers = 0, stops = 0;
        foreach (var s in states)
        {
            var el = AuthScreens.Build(s, _ => answers++, () => stops++);
            el.Measure(new Size(800, 600));
            el.Arrange(new Rect(0, 0, 800, 600));
            Check(el.DesiredSize.Width > 0 && el.DesiredSize.Height > 0, $"{s.Kind} has a size");
            Check(Title(s).Length > 0, $"{s.Kind} has a title");
            Check(Buttons(s).Count > 0, $"{s.Kind} has a button");
            Check(IsScreen(s), $"{s.Kind} is a screen");
            Check(!Body(s).Contains("{") && !Body(s).Contains("<"), $"{s.Kind} wording has no placeholder left");
        }

        // The wording that matters for safety.
        var changed = states[2];
        Check(Buttons(changed).SequenceEqual(new[] { "Close" }), "changed identity has only Close");
        Check(Rows(changed).Count == 2 && Rows(changed)[0].Contains("AB12-CD34-EF56-7890") && Rows(changed)[1].Contains("9999-8888-7777-6666"),
            "changed identity shows both fingerprints");
        Check(Body(changed).Contains("Nothing was sent to it."), "changed identity says nothing was sent");
        Check(Buttons(states[3]).SequenceEqual(new[] { "Close" }), "did not identify has only Close");
        Check(Buttons(states[4]).SequenceEqual(new[] { "Connect", "Cancel" }), "unverified asks Connect or Cancel");
        Check(Body(states[4]).Contains("studio.local:5903"), "unverified names the address");
        Check(Buttons(states[1]).SequenceEqual(new[] { "Connect", "Cancel" }), "confirm host asks Connect or Cancel");
        Check(Rows(states[0]).Count == 2, "waiting shows both fingerprints");
        Check(Body(states[7]).Contains("15 s"), "busy shows the delay");
        Check(Body(states[8]).Contains("Keychain approval"), "keychain state names the cause");
        Check(Body(states[9]).Contains("Remote access is off"), "remote-off state names the cause");
        Check(!IsScreen(FlowState.Connected(true, "Studio")) && !IsScreen(FlowState.Connecting()), "connected and connecting are not screens");

        // Buttons do what they say.
        var q = (Border)AuthScreens.Build(states[4], y => answers += y ? 10 : 100, () => stops++);
        var qs = (StackPanel)((StackPanel)((ScrollViewer)q.Child).Content).Children[^1];
        ((Button)qs.Children[0]).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        ((Button)qs.Children[1]).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        Check(answers == 110, "Connect answers yes and Cancel answers no");
        var c = (Border)AuthScreens.Build(changed, _ => answers++, () => stops += 1000);
        var cs = (StackPanel)((StackPanel)((ScrollViewer)c.Child).Content).Children[^1];
        ((Button)cs.Children[0]).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        Check(stops == 1000, "Close stops and does not answer");

        // Stop on a final screen closes the window (the viewer has no start screen).
        var window = new MainWindow();
        bool windowClosed = false;
        window.Closed += (_, _) => windowClosed = true;
        window.OnState(states[5]); // denied
        var wc = window.ScreenForTest as Border;
        Check(wc != null, "the window shows the denied screen");
        if (wc != null)
        {
            var ws = (StackPanel)((StackPanel)((ScrollViewer)wc.Child).Content).Children[^1];
            ((Button)ws.Children[0]).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        }
        Check(windowClosed, "Close on a final screen closes the window");

        var badge = BuildNotVerifiedBadge();
        badge.Measure(new Size(400, 100));
        Check(badge.DesiredSize.Width > 0, "Not verified label has a size");

        Log.Line(failed == 0 ? "selftest-screens: all checks passed" : $"selftest-screens: {failed} failed");
        return failed;
    }
}
