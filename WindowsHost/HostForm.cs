using System.Drawing;
using System.Windows.Forms;

namespace LivioRemote.WindowsHost;

public sealed class HostForm : Form
{
    private static readonly Color Ink = Color.FromArgb(35, 39, 45);
    private static readonly Color Muted = Color.FromArgb(84, 92, 101);
    private readonly Label status = new() { Dock = DockStyle.Fill, AutoSize = true, ForeColor = Ink };
    private readonly Label details = new() { Dock = DockStyle.Fill, AutoSize = true, ForeColor = Muted };
    private readonly Button start = new() { Text = "开始共享", AutoSize = true };
    private readonly Button preapprove = new() { Text = "单次预授权…", AutoSize = true };
    private readonly Button stop = new() { Text = "停止共享", AutoSize = true, Enabled = false };
    private readonly TableLayoutPanel invite = new() { Dock = DockStyle.Top, AutoSize = true, ColumnCount = 1, Visible = false };
    private readonly ComboBox addresses = new() { Dock = DockStyle.Top, DropDownStyle = ComboBoxStyle.DropDown };
    private readonly NumericUpDown advertisedPort = new()
    {
        Dock = DockStyle.Top, Minimum = 1, Maximum = 65535, Value = HostService.Port, ThousandsSeparator = false
    };
    private readonly Button copyInvite = new() { Text = "复制连接邀请（含密钥）", AutoSize = true, Anchor = AnchorStyles.Left };
    private readonly TextBox pin = Field();
    private readonly TextBox secret = Field();
    private CancellationTokenSource? running;
    private Access? unattended;
    private DateTimeOffset expires;

    public HostForm()
    {
        Text = "nnremote · 共享本机";
        Font = new Font("Microsoft YaHei UI", 10f);
        ForeColor = Ink;
        StartPosition = FormStartPosition.CenterScreen;
        AutoScaleMode = AutoScaleMode.Dpi;
        MinimumSize = new Size(560, 500);
        Size = new Size(680, 680);
        AutoScroll = true;
        var layout = new TableLayoutPanel
        {
            Dock = DockStyle.Top, ColumnCount = 1, Padding = new Padding(22),
            AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink
        };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        Controls.Add(layout);
        Add(layout, new Label { Text = "共享本机桌面", Font = new Font(Font.FontFamily, 19f, FontStyle.Bold), AutoSize = true });
        Add(layout, status);
        Add(layout, details);
        var buttons = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, WrapContents = true };
        buttons.Controls.AddRange([start, preapprove, stop]);
        Add(layout, buttons);
        invite.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        Add(invite, LabelFor($"邀请地址 · 可填局域网地址、Tailscale 地址或中继域名（IPv6 无方括号）"));
        Add(invite, addresses);
        Add(invite, LabelFor($"邀请端口 · 本机固定监听 TCP {HostService.Port}，使用中继时可填写对外端口。"));
        Add(invite, advertisedPort);
        Add(invite, LabelFor("证书指纹 · SHA-256"));
        Add(invite, pin);
        Add(invite, LabelFor("配对密钥"));
        Add(invite, secret);
        Add(invite, copyInvite);
        copyInvite.Click += (_, _) => CopyInvitation();
        Add(invite, LabelFor("邀请含有本次密钥，只通过可信渠道发送给预期的设备使用者。"));
        Add(layout, invite);
        start.Click += async (_, _) => await Start(null);
        preapprove.Click += async (_, _) =>
        {
            using var dialog = ConsentDialog.ForPreapproval();
            if (dialog.ShowDialog(this) == DialogResult.OK)
                await Start(dialog.AccessChoice);
        };
        stop.Click += (_, _) => running?.Cancel();
        Shown += (_, _) => Desktop.ExcludeFromCapture(this);
        FormClosing += (_, _) => running?.Cancel();
        ShowOff();
    }

    private static Label LabelFor(string value) =>
        new() { Text = value, Dock = DockStyle.Top, AutoSize = true, ForeColor = Muted };
    private static TextBox Field() => new() { Dock = DockStyle.Top, ReadOnly = true, WordWrap = false };
    private static void Add(TableLayoutPanel group, Control control)
    {
        int row = group.RowCount++;
        group.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        control.Margin = new Padding(3, 5, 3, 4);
        group.Controls.Add(control, 0, row);
    }

    private void ShowOff()
    {
        status.Text = "共享已关闭";
        details.Text = "常规共享需要你在这台电脑上批准每次连接。";
        start.Enabled = preapprove.Enabled = true;
        stop.Enabled = invite.Visible = false;
        addresses.Items.Clear();
        addresses.Text = "";
        advertisedPort.Value = HostService.Port;
        copyInvite.Text = "复制连接邀请（含密钥）";
        pin.Clear();
        secret.Clear();
    }

    private void CopyInvitation()
    {
        if (running == null || running.IsCancellationRequested || !invite.Visible) return;
        var host = addresses.Text.Trim();
        if (host.Length is < 1 or > 253 || host.IndexOfAny(['[', ']', '|']) >= 0 ||
            host.Any(c => char.IsWhiteSpace(c) || char.IsControl(c)) ||
            !(System.Net.IPAddress.TryParse(host, out _) || Uri.CheckHostName(host) == UriHostNameType.Dns))
        {
            MessageBox.Show(this, "请填写对方可达的 IP 地址或域名。IPv6 地址无需方括号。", Text);
            return;
        }
        string port = ((int)advertisedPort.Value).ToString(System.Globalization.CultureInfo.InvariantCulture);
        var line = $"LRV1|{host}|{port}|{pin.Text.Replace(" ", "")}|{secret.Text}";
        try
        {
            var data = new DataObject();
            data.SetText(line, TextDataFormat.UnicodeText);
            // Windows' private clipboard marker keeps the invite out of clipboard history and cloud sync.
            data.SetData("ExcludeClipboardContentFromMonitorProcessing", false, new MemoryStream(new byte[4]));
            Clipboard.SetDataObject(data, true, 3, 50);
            copyInvite.Text = "已复制 · 再次复制邀请";
        }
        catch (System.Runtime.InteropServices.ExternalException)
        {
            MessageBox.Show(this, "剪贴板暂不可用。请重新复制，或分别选中并复制各字段。", Text);
        }
    }

    private void UpdateState(string message, bool waiting)
    {
        invite.Visible = waiting;
        status.Text = waiting && unattended.HasValue
            ? $"等待一次已预授权的连接 · {(unattended == Access.Control ? "可控制" : "仅查看")}" : message;
        details.Text = unattended.HasValue
            ? $"到 {expires.LocalDateTime:HH:mm} 自动关闭。停止共享或本次断开后，邀请立即失效。"
            : waiting ? "这里列出本机网卡的地址，选择对方可达的一个。"
            : "可随时点击「停止共享」断开连接。";
    }

    private async Task Start(Access? allowOnce)
    {
        if (running is not null) return;
        using var session = new CancellationTokenSource();
        running = session;
        unattended = allowOnce;
        expires = DateTimeOffset.Now.AddHours(8);
        start.Enabled = preapprove.Enabled = false;
        stop.Enabled = true;
        if (allowOnce.HasValue) session.CancelAfter(TimeSpan.FromHours(8));
        string? error = null;
        try
        {
            using var host = new HostService(ConfirmPeer, (message, waiting) =>
                Post(() => { if (running == session && !session.IsCancellationRequested) UpdateState(message, waiting); }),
                allowOnce.HasValue);
            addresses.Items.AddRange(host.Addresses());
            addresses.SelectedIndex = 0;
            pin.Text = host.Fingerprint;
            secret.Text = host.Secret;
            UpdateState("等待连接。每次请求都需在这里确认。", true);
            await Task.Run(() => host.RunAsync(session.Token));
        }
        catch (Exception ex)
        {
            if (!session.IsCancellationRequested) error = ex.Message;
        }
        finally
        {
            running = null;
            unattended = null;
            if (!IsDisposed && !Disposing)
            {
                ShowOff();
                if (error != null) status.Text = $"共享已关闭 · {error}";
            }
        }
    }

    private bool Post(Action action)
    {
        try
        {
            if (!IsHandleCreated || IsDisposed) return false;
            BeginInvoke(action);
            return true;
        }
        catch (InvalidOperationException) { return false; }
    }

    private async Task<Access> ConfirmPeer(string peer, CancellationToken token)
    {
        var decision = new TaskCompletionSource<Access>(TaskCreationOptions.RunContinuationsAsynchronously);
        using var cancellation = token.Register(() => decision.TrySetCanceled(token));
        if (!Post(() =>
        {
            if (token.IsCancellationRequested) return;
            Access grant;
            if (unattended.HasValue)
            {
                if (DateTimeOffset.Now >= expires)
                {
                    running?.Cancel();
                    return;
                }
                grant = unattended.Value;
            }
            else
            {
                using var dialog = ConsentDialog.ForPeer(peer, token, () => running?.Cancel());
                grant = dialog.ShowDialog(this) == DialogResult.OK ? dialog.AccessChoice : Access.Denied;
            }
            if (grant != Access.Denied)
            {
                // Hide credentials before releasing the first frame.
                invite.Visible = false;
                UpdateState($"已允许 {peer} 连接", false);
                Refresh();
            }
            decision.TrySetResult(grant);
        })) return Access.Denied;
        return await decision.Task;
    }
}

internal sealed class ConsentDialog : Form
{
    internal Access AccessChoice { get; private set; } = Access.Denied;
    private readonly System.Windows.Forms.Timer? timer;

    public static ConsentDialog ForPreapproval() => new(null, CancellationToken.None, null);
    public static ConsentDialog ForPeer(string peer, CancellationToken token, Action stop) => new(peer, token, stop);

    private ConsentDialog(string? peer, CancellationToken token, Action? stop)
    {
        bool ownInvite = peer is null;
        Text = ownInvite ? "单次预授权" : "桌面共享请求";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        StartPosition = FormStartPosition.CenterParent;
        MinimizeBox = MaximizeBox = false;
        Font = new Font("Microsoft YaHei UI", 10f);
        AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new Size(520, 216);
        var body = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, Padding = new Padding(16), RowCount = 2 };
        body.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        body.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        var message = new Label
        {
            AutoSize = false, Dock = DockStyle.Fill,
            Text = ownInvite
                ? "允许下一台持有本次密钥的设备连接这台电脑？连接时无需人在场。请只把密钥给你信任的设备。邀请和会话最长 8 小时，断开后失效。"
                : $"来自 {peer} 的设备已验证配对密钥。仅查看可看见主屏幕；允许控制还可移动鼠标、点击和输入文字。请选择本次权限。"
        };
        body.Controls.Add(message, 0, 0);
        var buttons = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoSize = true, WrapContents = true };
        var deny = new Button { Text = ownInvite ? "取消" : "拒绝", DialogResult = DialogResult.Cancel, AutoSize = true };
        buttons.Controls.Add(deny);
        foreach (var (label, access) in new[] { ("仅查看", Access.View), ("允许控制", Access.Control) })
        {
            var button = new Button { Text = label, AutoSize = true };
            button.Click += (_, _) => { AccessChoice = access; DialogResult = DialogResult.OK; };
            buttons.Controls.Add(button);
        }
        if (stop != null)
        {
            var stopButton = new Button { Text = "停止共享", AutoSize = true };
            stopButton.Click += (_, _) => { stop(); DialogResult = DialogResult.Cancel; };
            buttons.Controls.Add(stopButton);
        }
        CancelButton = deny;
        body.Controls.Add(buttons, 0, 1);
        Controls.Add(body);
        Shown += (_, _) => { Desktop.ExcludeFromCapture(this); deny.Focus(); };
        if (!ownInvite)
        {
            var deadline = System.Diagnostics.Stopwatch.StartNew();
            timer = new System.Windows.Forms.Timer { Interval = 250 };
            timer.Tick += (_, _) =>
            {
                if (token.IsCancellationRequested || deadline.Elapsed >= TimeSpan.FromSeconds(40))
                    DialogResult = DialogResult.Cancel;
            };
            Shown += (_, _) => timer.Start();
        }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) timer?.Dispose();
        base.Dispose(disposing);
    }
}
