using System.Buffers.Binary;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;

namespace LivioRemote.Windows;

internal sealed class ViewerLink : IDisposable
{
    private readonly TcpClient socket = new() { NoDelay = true };
    private readonly CancellationTokenSource lifetime = new();
    private readonly SemaphoreSlim writer = new(1, 1);
    private SslStream? tls;
    public bool MayControl { get; private set; }

    public static byte[] ReadHex(string input, int bytes, bool allowSeparators)
    {
        string cleaned = allowSeparators
            ? new string(input.Where(c => !char.IsWhiteSpace(c) && c != ':' && c != '-').ToArray())
            : input.Trim();
        if (cleaned.Length != bytes * 2 || !cleaned.All(Uri.IsHexDigit))
            throw new FormatException(bytes == 32 ? "请填写主机显示的完整 SHA-256 指纹（64 位十六进制）。" : "配对密钥需要 32 位十六进制字符。");
        return Convert.FromHexString(cleaned);
    }

    public async Task<bool> ConnectAsync(string host, int port, byte[] pin, byte[] secret, Action awaitingApproval)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        deadline.CancelAfter(TimeSpan.FromSeconds(15));
        await socket.ConnectAsync(host, port, deadline.Token);
        tls = new SslStream(socket.GetStream(), false, (_, cert, _, _) =>
            cert != null && CryptographicOperations.FixedTimeEquals(cert.GetCertHash(HashAlgorithmName.SHA256), pin));
        await tls.AuthenticateAsClientAsync(new SslClientAuthenticationOptions
        {
            TargetHost = host,
            EnabledSslProtocols = SslProtocols.Tls12 | SslProtocols.Tls13,
            CertificateRevocationCheckMode = X509RevocationMode.NoCheck
        }, deadline.Token);
        await WriteAsync(1, Encoding.ASCII.GetBytes(Convert.ToHexString(secret)), deadline.Token);
        awaitingApproval();
        deadline.CancelAfter(TimeSpan.FromMinutes(2));
        var (type, length) = await HeaderAsync(deadline.Token);
        if (length != 0 || type is not (2 or 3 or 4)) throw new InvalidDataException("主机发来了无法识别的授权结果。");
        MayControl = type == 3;
        return type != 4;
    }

    private async Task<(byte, int)> HeaderAsync(CancellationToken ct)
    {
        byte[] h = new byte[5];
        await tls!.ReadExactlyAsync(h.AsMemory(), ct);
        int n = BinaryPrimitives.ReadInt32BigEndian(h.AsSpan(1));
        if (n < 0 || n > 8 * 1024 * 1024) throw new InvalidDataException("画面数据超过限制。");
        return (h[0], n);
    }

    public async Task<Bitmap?> NextFrameAsync()
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        deadline.CancelAfter(TimeSpan.FromSeconds(90));
        var (type, n) = await HeaderAsync(deadline.Token);
        if (type == 5 && n == 0) return null;
        if (type != 16 || n < 4) throw new InvalidDataException("主机发送的画面格式无效。");
        byte[] data = new byte[n];
        await tls!.ReadExactlyAsync(data.AsMemory(), deadline.Token);
        return await Task.Run(() => DecodeFrame(data), deadline.Token);
    }

    private static Bitmap DecodeFrame(byte[] data)
    {
        // Check JPEG dimensions before passing compressed data to the Windows decoder.
        bool valid = false;
        if (data[0] == 0xff && data[1] == 0xd8)
        {
            int i = 2;
            while (i + 4 <= data.Length && data[i] == 0xff)
            {
                while (i < data.Length && data[i] == 0xff) i++;
                if (i + 2 >= data.Length) break;
                int marker = data[i++];
                int len = BinaryPrimitives.ReadUInt16BigEndian(data.AsSpan(i, 2));
                if (len < 2 || i + len > data.Length) break;
                if (marker is 0xc0 or 0xc1 or 0xc2)
                {
                    if (len >= 8)
                    {
                        int h = BinaryPrimitives.ReadUInt16BigEndian(data.AsSpan(i + 3, 2));
                        int w = BinaryPrimitives.ReadUInt16BigEndian(data.AsSpan(i + 5, 2));
                        valid = w > 0 && h > 0 && w <= 1920 && h <= 1080;
                    }
                    break;
                }
                if (marker is 0xda or 0xd9) break;
                i += len;
            }
        }
        if (!valid) throw new InvalidDataException("收到的 JPEG 格式或尺寸无效。");
        using var buf = new MemoryStream(data, false);
        using var img = Image.FromStream(buf, useEmbeddedColorManagement: false, validateImageData: true);
        return new Bitmap(img);
    }

    public Task InputAsync(byte type, byte[] payload) =>
        MayControl ? WriteAsync(type, payload, lifetime.Token) : Task.CompletedTask;

    private async Task WriteAsync(byte type, byte[] data, CancellationToken ct)
    {
        byte[] record = new byte[5 + data.Length];
        record[0] = type;
        BinaryPrimitives.WriteInt32BigEndian(record.AsSpan(1, 4), data.Length);
        data.CopyTo(record, 5);
        await writer.WaitAsync(ct);
        try { await tls!.WriteAsync(record.AsMemory(), ct); }
        finally { writer.Release(); }
    }

    public void Dispose()
    {
        if (lifetime.IsCancellationRequested) return;
        MayControl = false;
        lifetime.Cancel();
        socket.Dispose();
        tls?.Dispose();
    }
}
