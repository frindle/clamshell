using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace Clamshell;

/// <summary>The "Unlock disk" and "Restart" forms. Plain WPF in code, like AuthScreens.
/// The caller gets the typed account once, through the callback, and the password box is
/// cleared straight away. Saving is the caller's job and only when the box is ticked.</summary>
internal static class UnlockScreens
{
    public static UIElement Build(string title, string text, string action, bool offerSave,
        (string Username, string Password)? saved, Action<string, string, bool> go, Action cancel, out TextBlock note)
    {
        var panel = new StackPanel { Margin = new Thickness(24), MaxWidth = 460, VerticalAlignment = VerticalAlignment.Center };
        panel.Children.Add(new TextBlock { Text = title, FontSize = 22, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 12) });
        panel.Children.Add(new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 12) });
        var user = new TextBox { Text = saved?.Username ?? "", Margin = new Thickness(0, 0, 0, 8), Padding = new Thickness(4) };
        var pass = new PasswordBox { Password = saved?.Password ?? "", Margin = new Thickness(0, 0, 0, 8), Padding = new Thickness(4) };
        var save = new CheckBox { Content = "Save on this device (Windows Credential Manager)", IsChecked = saved is not null, Margin = new Thickness(0, 0, 0, 8) };
        panel.Children.Add(user);
        panel.Children.Add(pass);
        if (offerSave) panel.Children.Add(save);
        var status = new TextBlock { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 4) };
        panel.Children.Add(status);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 8, 0, 0) };
        var ok = new Button { Content = action, MinWidth = 90, Margin = new Thickness(0, 0, 8, 0), Padding = new Thickness(10, 4, 10, 4) };
        ok.Click += (_, _) =>
        {
            var u = user.Text; var p = pass.Password;
            if (u.Length == 0 || p.Length == 0) return;
            bool keep = offerSave && save.IsChecked == true;
            pass.Clear();
            go(u, p, keep);
        };
        var no = new Button { Content = "Not now", MinWidth = 90, Padding = new Thickness(10, 4, 10, 4) };
        no.Click += (_, _) => cancel();
        buttons.Children.Add(ok);
        buttons.Children.Add(no);
        panel.Children.Add(buttons);
        note = status;
        return new Border
        {
            Background = new SolidColorBrush(Color.FromRgb(0xF4, 0xF4, 0xF4)),
            Child = new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto },
        };
    }
}
