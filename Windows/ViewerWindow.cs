using System.Buffers.Binary;
using System.Net;
using System.Security.Authentication;
using System.Text;

namespace LivioRemote.Windows;

internal sealed class ViewerWindow : Form
{
    private readonly TextBox address = new() { PlaceholderText = "主机地址或名称", Dock = DockStyle.Fill };
    private readonly NumericUpDown port = new() { Minimum = 1, Maximum = 65535, Value = 47831, Width = 78 };
    private readonly TextBox pin = new() { PlaceholderText = "主机的完整 SHA-256 指纹", Dock = DockStyle.Fill };
    private readonly TextBox secret = new() { PlaceholderText = "32 位配对密钥", UseSystemPasswordChar = true, Dock = DockStyle.Fill };
    private readonly Button connect = new() { Text = "连接", AutoSize = true };
    private readonly Label status = new() { Text = "从主机复制地址、指纹和密钥。", AutoSize = true, Padding = new Padding(4, 6, 4, 2) };
    private readonly PictureBox screen = new() { BackColor = Color.FromArgb(25, 28, 33), Dock = DockStyle.Fill, SizeMode = PictureBoxSizeMode.Zoom };
    private readonly TextBox textInput = new() { Width = 235, MaxLength = 1024, PlaceholderText = "输入文字发到远端" };
    private readonly FlowLayoutPanel inputBar = new() { AutoSize = true, Dock = DockStyle.Fill, Visible = false, WrapContents = true };
    private readonly TableLayoutPanel fields = new() { AutoSize = true, ColumnCount = 3, Dock = DockStyle.Top };
    private ViewerLink? current;
    private ushort pointerX = 32768, pointerY = 32768;
    private MouseButtons pressedButtons;
    private bool recaptureAfterMouseUp;
    private readonly System.Windows.Forms.Timer pointerTimer = new() { Interval = 16 };
    private bool movePending;
    private Task? moveWrite;
    private int wheelRemainder;
    private readonly Button paste = new() { Text = "粘贴连接邀请", AutoSize = true };


    public ViewerWindow()
    {
        Text = "连接电脑 · nnremote";
        Font = new Font("Microsoft YaHei UI", 10);
        StartPosition = FormStartPosition.CenterParent;
        Size = new Size(1040, 760);
        MinimumSize = new Size(630, 460);
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 4, Padding = new Padding(10) };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        fields.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        fields.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        fields.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        AddField(0, "主机", address);
        fields.Controls.Add(port, 2, 0);
        AddField(1, "证书指纹", pin);
        AddField(2, "配对密钥", secret);
        var actions = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoSize = true };
        paste.Click += (_, _) => ImportInvitation();
        actions.Controls.Add(paste);
        actions.Controls.Add(connect);
        actions.Controls.Add(status);
        layout.Controls.Add(fields, 0, 0);
        layout.Controls.Add(actions, 0, 1);
        layout.Controls.Add(screen, 0, 2);
        layout.Controls.Add(inputBar, 0, 3);
        var sendText = new Button { Text = "发送文字", AutoSize = true };
        sendText.Click += async (_, _) =>
        {
            var value = Encoding.UTF8.GetBytes(textInput.Text);
            if (value.Length == 0) return;
            if (value.Length > 1024) { status.Text = "每次最多发送 1024 字节。"; return; }
            if (await SendInput(33, value)) textInput.Clear();
        };
        inputBar.Controls.Add(textInput);
        inputBar.Controls.Add(sendText);
        foreach (var (name, value) in new[] { ("回车", 1), ("退格", 2), ("Tab", 3), ("Esc", 4) })
        {
            var key = new Button { Text = name, AutoSize = true };
            key.Click += async (_, _) => await SendInput(34, [(byte)value]);
            inputBar.Controls.Add(key);
        }
        foreach (var (label, ticks) in new[] { ("上滚", 3), ("下滚", -3) })
        {
            var button = new Button { Text = label, AutoSize = true };
            button.Click += async (_, _) => await QueueScroll(pointerX, pointerY, ticks);
            inputBar.Controls.Add(button);
        }
        screen.MouseMove += (_, e) => PointerMoved(e.Location);
        screen.MouseDown += async (_, e) => await PointerDown(e);
        screen.MouseUp += async (_, e) => await PointerUp(e);
        screen.MouseCaptureChanged += async (_, _) =>
        {
            // WinForms drops capture after every mouse-up, even when another button is still down.
            if (recaptureAfterMouseUp && !screen.Capture && Form.ActiveForm == this)
            {
                recaptureAfterMouseUp = false;
                screen.Capture = true;
            }
            if (!screen.Capture) await ReleaseButtons();
        };
        Deactivate += async (_, _) => await ReleaseButtons();
        screen.MouseWheel += async (_, e) => await ScrollAt(screen.PointToScreen(e.Location), e);
        MouseWheel += async (_, e) => await ScrollAt(PointToScreen(e.Location), e);
        pointerTimer.Tick += (_, _) =>
        {
            if (moveWrite?.IsCompleted != false) moveWrite = FlushPendingMove();
        };
        connect.Click += async (_, _) =>
        {
            if (current != null) { Stop("已断开"); return; }
            await StartAsync();
        };
        FormClosing += (_, _) => Stop("已断开");
        Controls.Add(layout);
    }

    private bool MapPointer(Point location, bool clamp, out ushort x, out ushort y)
    {
        x = y = 0;
        return screen.Image is { } img && PointerGeometry.TryMap(screen.ClientSize, img.Size, location, out x, out y, clamp);
    }

    private void PointerMoved(Point location)
    {
        if (current?.ExtendedPointer != true || Form.ActiveForm != this ||
            !MapPointer(location, pressedButtons != MouseButtons.None, out var x, out var y)) return;
        if (x == pointerX && y == pointerY) return;
        (pointerX, pointerY) = (x, y);
        movePending = true;
    }

    private Task PointerDown(MouseEventArgs e)
    {
        if (current?.MayControl != true || e.Button is not (MouseButtons.Left or MouseButtons.Right) ||
            pressedButtons.HasFlag(e.Button) || !MapPointer(e.Location, false, out var x, out var y))
            return Task.CompletedTask;
        pressedButtons |= e.Button;
        screen.Capture = true;
        return current.ExtendedPointer ? QueuePointer(x, y, e.Button == MouseButtons.Left ? (byte)3 : (byte)5)
            : Task.CompletedTask;
    }

    private Task PointerUp(MouseEventArgs e)
    {
        if (e.Button is not (MouseButtons.Left or MouseButtons.Right) || !pressedButtons.HasFlag(e.Button))
            return Task.CompletedTask;
        pressedButtons &= ~e.Button;
        recaptureAfterMouseUp = pressedButtons != MouseButtons.None;
        if (current?.ExtendedPointer == true)
        {
            if (!MapPointer(e.Location, true, out var x, out var y)) (x, y) = (pointerX, pointerY);
            return QueuePointer(x, y, e.Button == MouseButtons.Left ? (byte)4 : (byte)6);
        }
        return MapPointer(e.Location, false, out var clickX, out var clickY)
            ? QueuePointer(clickX, clickY, e.Button == MouseButtons.Left ? (byte)1 : (byte)2)
            : Task.CompletedTask;
    }

    private Task ReleaseButtons()
    {
        var held = pressedButtons;
        pressedButtons = MouseButtons.None;
        recaptureAfterMouseUp = false;
        if (screen.Capture) screen.Capture = false;
        if (current?.ExtendedPointer != true || held == MouseButtons.None) return Task.CompletedTask;
        return Task.WhenAll(
            held.HasFlag(MouseButtons.Left) ? QueuePointer(pointerX, pointerY, 4) : Task.CompletedTask,
            held.HasFlag(MouseButtons.Right) ? QueuePointer(pointerX, pointerY, 6) : Task.CompletedTask);
    }

    private Task FlushPendingMove()
    {
        if (!movePending) return Task.CompletedTask;
        movePending = false;
        return SendPointer(pointerX, pointerY, 0);
    }

    private Task QueuePointer(ushort x, ushort y, byte action)
    {
        var precedingMove = FlushPendingMove();
        (pointerX, pointerY) = (x, y);
        return Task.WhenAll(precedingMove, SendPointer(x, y, action));
    }

    private Task SendPointer(ushort x, ushort y, byte action)
    {
        byte[] payload = new byte[5];
        BinaryPrimitives.WriteUInt16BigEndian(payload.AsSpan(0, 2), x);
        BinaryPrimitives.WriteUInt16BigEndian(payload.AsSpan(2, 2), y);
        payload[4] = action;
        return SendInput(32, payload);
    }

    private Task ScrollAt(Point screenLocation, MouseEventArgs e)
    {
        if (current?.MayControl != true || !MapPointer(screen.PointToClient(screenLocation), false, out var x, out var y))
            return Task.CompletedTask;
        if (e is HandledMouseEventArgs handled) handled.Handled = true;
        wheelRemainder += e.Delta;
        int ticks = Math.Clamp(wheelRemainder / 120, -10, 10);
        wheelRemainder %= 120;
        return ticks == 0 ? Task.CompletedTask : QueueScroll(x, y, ticks);
    }

    private Task QueueScroll(ushort x, ushort y, int ticks)
    {
        var precedingMove = FlushPendingMove();
        (pointerX, pointerY) = (x, y);
        byte[] payload = new byte[6];
        BinaryPrimitives.WriteUInt16BigEndian(payload.AsSpan(0, 2), x);
        BinaryPrimitives.WriteUInt16BigEndian(payload.AsSpan(2, 2), y);
        BinaryPrimitives.WriteInt16BigEndian(payload.AsSpan(4, 2), (short)ticks);
        return Task.WhenAll(precedingMove, SendInput(35, payload));
    }

    private void ImportInvitation()
    {
        try
        {
            string line = Clipboard.GetText().Trim();
            string[] f = line.Split('|');
            if (line.Length > 512 || f.Length != 5 || f[0] != "LRV1" ||
                (!IPAddress.TryParse(f[1], out _) && Uri.CheckHostName(f[1]) != UriHostNameType.Dns) ||
                !ushort.TryParse(f[2], System.Globalization.NumberStyles.None,
                    System.Globalization.CultureInfo.InvariantCulture, out ushort number) || number == 0)
                throw new FormatException("请复制主机生成的完整连接邀请。");
            _ = ViewerLink.ReadHex(f[3], 32, false);
            _ = ViewerLink.ReadHex(f[4], 16, false);
            address.Text = f[1];
            port.Value = number;
            pin.Text = f[3];
            secret.Text = f[4];
            status.Text = "已填入邀请。确认来源后点击连接。";
        }
        catch (FormatException ex) { status.Text = ex.Message; }
        catch (System.Runtime.InteropServices.ExternalException) { status.Text = "剪贴板暂不可用，请重试。"; }
    }

    private void AddField(int row, string label, Control control)
    {
        fields.Controls.Add(new Label { Text = label, AutoSize = true, Anchor = AnchorStyles.Left }, 0, row);
        fields.Controls.Add(control, 1, row);
    }

    private async Task StartAsync()
    {
        string host = address.Text.Trim();
        if (host.StartsWith('[') && host.EndsWith(']')) host = host[1..^1];
        if (host.Length == 0 || (!IPAddress.TryParse(host, out _) && Uri.CheckHostName(host) != UriHostNameType.Dns))
        { status.Text = "请填写 IP 地址或主机名，端口填在右侧。"; return; }
        byte[] fingerprint, key;
        try { fingerprint = ViewerLink.ReadHex(pin.Text, 32, true); key = ViewerLink.ReadHex(secret.Text, 16, false); }
        catch (FormatException ex) { status.Text = ex.Message; return; }
        var session = new ViewerLink();
        current = session;
        connect.Text = "断开";
        fields.Visible = false;
        paste.Visible = false;
        status.Text = "正在连接并核对主机指纹…";
        string outcome = "主机已断开";
        try
        {
            bool approved = await session.ConnectAsync(host, (int)port.Value, fingerprint, key,
                () => { if (current == session) status.Text = "指纹已匹配，等待主机授权…"; });
            if (current != session) return;
            if (!approved) { outcome = "主机拒绝连接或配对密钥无效。"; return; }
            secret.Clear();
            inputBar.Visible = session.MayControl;
            status.Text = session.ExtendedPointer ? "已连接 · 可拖动、双击及滚动" : session.MayControl
                ? "已连接 · 可点击和滚动，升级主机后可拖动" : "已连接 · 仅查看";
            if (session.ExtendedPointer) pointerTimer.Start();
            while (current == session)
            {
                var frame = await session.NextFrameAsync();
                if (frame is null) break;
                if (current != session) { frame.Dispose(); break; }
                var old = screen.Image;
                screen.Image = frame;
                old?.Dispose();
            }
        }
        catch (AuthenticationException) { outcome = "TLS 验证失败。请从主机重新核对完整证书指纹。"; }
        catch (OperationCanceledException) { outcome = "连接或等待主机超时。"; }
        catch (EndOfStreamException) { outcome = "主机已断开"; }
        catch (Exception ex) { outcome = $"连接已结束：{ex.Message}"; }
        finally
        {
            System.Security.Cryptography.CryptographicOperations.ZeroMemory(key);
            if (current == session) Stop(outcome);
            else session.Dispose();
        }
    }

    private async Task<bool> SendInput(byte type, byte[] payload)
    {
        var target = current;
        if (target?.MayControl != true) return false;
        try { await target.InputAsync(type, payload); return target == current; }
        catch (Exception) { if (target == current) Stop("输入通道已断开"); return false; }
    }

    private void Stop(string message)
    {
        var session = current;
        current = null;
        session?.Dispose();
        pointerTimer.Stop();
        movePending = false;
        moveWrite = null;
        wheelRemainder = 0;
        pressedButtons = MouseButtons.None;
        recaptureAfterMouseUp = false;
        if (screen.Capture) screen.Capture = false;
        inputBar.Visible = false;
        textInput.Clear();
        var frame = screen.Image;
        screen.Image = null;
        frame?.Dispose();
        fields.Visible = true;
        paste.Visible = true;
        pointerX = pointerY = 32768;
        connect.Text = "连接";
        status.Text = message;
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) pointerTimer.Dispose();
        base.Dispose(disposing);
    }
}
