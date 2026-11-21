using LivioRemote.WindowsHost;

namespace LivioRemote.Windows;

internal static class Program
{
    [STAThread]
    static void Main()
    {
        ApplicationConfiguration.Initialize();
        Application.Run(new HomeWindow());
    }
}

internal sealed class HomeWindow : Form
{
    public HomeWindow()
    {
        Text = "Livio Remote";
        Font = new Font("Microsoft YaHei UI", 10);
        StartPosition = FormStartPosition.CenterScreen;
        Size = new Size(520, 300);
        MinimumSize = new Size(430, 270);
        var body = new FlowLayoutPanel
        {
            FlowDirection = FlowDirection.TopDown, Dock = DockStyle.Fill,
            Padding = new Padding(24), WrapContents = false, AutoScroll = true
        };
        body.Controls.Add(new Label { Text = "远程桌面", Font = new Font(Font.FontFamily, 22, FontStyle.Bold), AutoSize = true, Margin = new Padding(0, 0, 0, 18) });
        var connect = new Button { Text = "连接另一台电脑", AutoSize = true, Padding = new Padding(8, 4, 8, 4) };
        var host = new Button { Text = "共享这台电脑", AutoSize = true, Padding = new Padding(8, 4, 8, 4) };
        connect.Click += (_, _) => { using var form = new ViewerWindow(); form.ShowDialog(this); };
        host.Click += (_, _) => { using var form = new HostForm(); form.ShowDialog(this); };
        body.Controls.Add(connect);
        body.Controls.Add(host);
        Controls.Add(body);
    }
}
