using System.Buffers.Binary;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;

namespace LivioRemote.WindowsHost;

internal static class Desktop
{
    private const uint MouseInput = 0;
    private const uint KeyboardInput = 1;
    private const uint UnicodeFlag = 0x0004;
    private const uint KeyUp = 0x0002;
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);

    private static Rectangle ScreenBounds() =>
        Screen.PrimaryScreen?.Bounds ?? throw new InvalidOperationException("找不到主显示器。");

    public static byte[] Frame()
    {
        Rectangle bounds = ScreenBounds();
        using var source = new Bitmap(bounds.Width, bounds.Height, PixelFormat.Format24bppRgb);
        using (var graphics = Graphics.FromImage(source))
        {
            graphics.CopyFromScreen(bounds.Location, Point.Empty, bounds.Size);
            DrawCursor(graphics, bounds);
        }

        double scale = Math.Min(1d, Math.Min(1920d / bounds.Width, 1080d / bounds.Height));
        using var bytes = new MemoryStream();
        if (scale < 1d)
        {
            var size = new Size(Math.Max(1, (int)(bounds.Width * scale)), Math.Max(1, (int)(bounds.Height * scale)));
            using var resized = new Bitmap(size.Width, size.Height, PixelFormat.Format24bppRgb);
            using (var graphics = Graphics.FromImage(resized))
            {
                graphics.InterpolationMode = InterpolationMode.HighQualityBilinear;
                graphics.DrawImage(source, new Rectangle(Point.Empty, size));
            }
            resized.Save(bytes, ImageFormat.Jpeg);
        }
        else
        {
            source.Save(bytes, ImageFormat.Jpeg);
        }
        return bytes.ToArray();
    }

    private static void DrawCursor(Graphics graphics, Rectangle bounds)
    {
        var cursor = new CursorInfo { Size = Marshal.SizeOf<CursorInfo>() };
        if (!GetCursorInfo(ref cursor) || (cursor.Flags & 1) == 0 || !bounds.Contains(cursor.Location) ||
            !GetIconInfo(cursor.Cursor, out var icon)) return;
        try
        {
            IntPtr hdc = graphics.GetHdc();
            try
            {
                int x = cursor.Location.X - bounds.X - (int)icon.HotspotX;
                int y = cursor.Location.Y - bounds.Y - (int)icon.HotspotY;
                _ = DrawIconEx(hdc, x, y, cursor.Cursor, 0, 0, 0, IntPtr.Zero, 3);
            }
            finally { graphics.ReleaseHdc(hdc); }
        }
        finally
        {
            if (icon.Mask != IntPtr.Zero) _ = DeleteObject(icon.Mask);
            if (icon.Color != IntPtr.Zero) _ = DeleteObject(icon.Color);
        }
    }

    public static void Apply(byte type, byte[] bytes)
    {
        switch (type)
        {
            case 32 when bytes.Length == 5 && bytes[4] <= 2:
                MoveOrClick(bytes);
                return;
            case 35 when bytes.Length == 6:
                short ticks = BinaryPrimitives.ReadInt16BigEndian(bytes.AsSpan(4));
                if (ticks < -10 || ticks > 10) throw new InvalidDataException("滚轮步数无效。");
                if (ticks != 0 && PositionPointer(bytes))
                    Send([Mouse(0x0800, unchecked((uint)(ticks * 120)))]);
                return;
            case 33 when bytes.Length is > 0 and <= 1024:
                string text = StrictUtf8.GetString(bytes);
                // Single-line text only. Terminal and navigation keys use the explicit key command.
                if (text.Any(char.IsControl)) throw new InvalidDataException("文本含控制字符。");
                var keys = new List<Input>(text.Length * 2);
                foreach (var ch in text)
                {
                    keys.Add(Keyboard(0, ch, UnicodeFlag));
                    keys.Add(Keyboard(0, ch, UnicodeFlag | KeyUp));
                }
                Send(keys.ToArray());
                return;
            case 34 when bytes.Length == 1:
                ushort key = bytes[0] switch
                {
                    1 => 0x0D, 2 => 0x08, 3 => 0x09, 4 => 0x1B,
                    _ => throw new InvalidDataException("未知按键。")
                };
                Send([Keyboard(key, 0, 0), Keyboard(key, 0, KeyUp)]);
                return;
            default:
                throw new InvalidDataException("无效的控制指令。");
        }
    }

    private static void MoveOrClick(byte[] bytes)
    {
        if (!PositionPointer(bytes)) return;
        if (bytes[4] == 1) Send([Mouse(0x0002), Mouse(0x0004)]);
        if (bytes[4] == 2) Send([Mouse(0x0008), Mouse(0x0010)]);
    }

    private static bool PositionPointer(byte[] bytes)
    {
        var bounds = ScreenBounds();
        int x = bounds.X + (int)Math.Round(BinaryPrimitives.ReadUInt16BigEndian(bytes) / 65535d * (bounds.Width - 1));
        int y = bounds.Y + (int)Math.Round(BinaryPrimitives.ReadUInt16BigEndian(bytes.AsSpan(2)) / 65535d * (bounds.Height - 1));
        return SetCursorPos(x, y);
    }

    private static void Send(Input[] inputs)
    {
        // Windows may reject input to elevated/secure desktops. The host runs as the signed-in user.
        _ = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Input>());
    }

    internal static void ExcludeFromCapture(Form form)
    {
        // The invitation and consent UI should not appear in streamed images on supported Windows versions.
        _ = SetWindowDisplayAffinity(form.Handle, 0x11);
    }

    private static Input Mouse(uint flags, uint wheel = 0) =>
        new() { Type = MouseInput, Data = new Payload { Mouse = new MouseData { Flags = flags, MouseDataValue = wheel } } };
    private static Input Keyboard(ushort key, ushort scan, uint flags) =>
        new() { Type = KeyboardInput, Data = new Payload { Keyboard = new KeyData { Key = key, Scan = scan, Flags = flags } } };

    [StructLayout(LayoutKind.Sequential)]
    private struct Input { public uint Type; public Payload Data; }
    [StructLayout(LayoutKind.Explicit)]
    private struct Payload
    {
        [FieldOffset(0)] public MouseData Mouse;
        [FieldOffset(0)] public KeyData Keyboard;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct MouseData { public int X, Y; public uint MouseDataValue, Flags, Time; public UIntPtr Extra; }
    [StructLayout(LayoutKind.Sequential)]
    private struct KeyData { public ushort Key, Scan; public uint Flags, Time; public UIntPtr Extra; }

    [StructLayout(LayoutKind.Sequential)]
    private struct CursorInfo { public int Size; public uint Flags; public IntPtr Cursor; public Point Location; }
    [StructLayout(LayoutKind.Sequential)]
    private struct IconInfo { public int IsIcon; public uint HotspotX, HotspotY; public IntPtr Mask, Color; }

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetCursorInfo(ref CursorInfo info);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetIconInfo(IntPtr handle, out IconInfo info);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DrawIconEx(IntPtr dc, int x, int y, IntPtr icon, int width, int height,
        uint step, IntPtr brush, uint flags);
    [DllImport("gdi32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DeleteObject(IntPtr obj);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint count, [In] Input[] inputs, int size);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowDisplayAffinity(IntPtr window, uint affinity);
}
