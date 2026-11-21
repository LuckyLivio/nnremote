using System.Buffers.Binary;
using System.Diagnostics;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;

namespace LivioRemote.WindowsHost;

internal enum Access : byte { Denied = 4, View = 2, Control = 3 }

internal sealed class HostService : IDisposable
{
    public const int Port = 47831;
    private const int MaxFrame = 8 * 1024 * 1024;
    private readonly TcpListener listener;
    private readonly X509Certificate2 certificate;
    private readonly byte[] secret;
    private readonly Func<string, CancellationToken, Task<Access>> confirm;
    private readonly Action<string, bool> status;
    private readonly bool singleUse;
    private bool claimed;
    public string Secret => Convert.ToHexString(secret);
    public string Fingerprint => string.Join(" ", certificate.GetCertHash(HashAlgorithmName.SHA256)
        .Select(b => b.ToString("X2")));

    public HostService(Func<string, CancellationToken, Task<Access>> confirm, Action<string, bool> status, bool singleUse)
    {
        this.singleUse = singleUse;
        this.confirm = confirm;
        this.status = status;
        certificate = MakeCertificate();
        secret = RandomNumberGenerator.GetBytes(16);
        try
        {
            listener = StartListener();
        }
        catch
        {
            certificate.Dispose();
            CryptographicOperations.ZeroMemory(secret);
            throw;
        }
    }

    private static TcpListener StartListener()
    {
        if (Socket.OSSupportsIPv6)
        {
            var dual = new TcpListener(IPAddress.IPv6Any, Port);
            try
            {
                dual.Server.DualMode = true;
                dual.Start(4);
                return dual;
            }
            catch (Exception e) when (e is SocketException or NotSupportedException)
            {
                dual.Stop();
            }
        }
        var ipv4 = new TcpListener(IPAddress.Any, Port);
        try
        {
            ipv4.Start(4);
            return ipv4;
        }
        catch
        {
            ipv4.Stop();
            throw;
        }
    }

    public string[] Addresses()
    {
        bool ipv6 = listener.Server.AddressFamily == AddressFamily.InterNetworkV6;
        var addresses = NetworkInterface.GetAllNetworkInterfaces()
            .Where(n => n.OperationalStatus == OperationalStatus.Up && n.NetworkInterfaceType != NetworkInterfaceType.Loopback)
            .SelectMany(n => n.GetIPProperties().UnicastAddresses)
            .Select(info => info.Address)
            .Where(ip => ip.AddressFamily == AddressFamily.InterNetwork ||
                (ipv6 && ip.AddressFamily == AddressFamily.InterNetworkV6 && !ip.IsIPv6LinkLocal))
            .Distinct()
            .OrderBy(ip => ip.AddressFamily == AddressFamily.InterNetwork ? 0 : 1)
            .Select(ip => ip.ToString()).ToArray();
        return addresses.Length > 0 ? addresses : ["127.0.0.1"];
    }

    private static X509Certificate2 MakeCertificate()
    {
        using var rsa = RSA.Create(2048);
        var request = new CertificateRequest("CN=Livio Remote", rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
        request.CertificateExtensions.Add(new X509KeyUsageExtension(
            X509KeyUsageFlags.DigitalSignature | X509KeyUsageFlags.KeyEncipherment, true));
        request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(
            new OidCollection { new("1.3.6.1.5.5.7.3.1") }, false));
        using var created = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddMinutes(-10), DateTimeOffset.UtcNow.AddDays(30));
        // Re-import into Schannel's normal per-user key context. Disposing the cert releases the temporary key.
        var password = Convert.ToHexString(RandomNumberGenerator.GetBytes(24));
        var pfx = created.Export(X509ContentType.Pfx, password);
        try { return X509CertificateLoader.LoadPkcs12(pfx, password, X509KeyStorageFlags.UserKeySet); }
        finally { CryptographicOperations.ZeroMemory(pfx); }
    }

    public async Task RunAsync(CancellationToken stopping)
    {
        while (!stopping.IsCancellationRequested)
        {
            using var tcp = await listener.AcceptTcpClientAsync(stopping);
            tcp.NoDelay = true;
            try
            {
                await ServeOne(tcp, stopping);
            }
            catch (Exception error) when (error is IOException or SocketException or AuthenticationException
                or OperationCanceledException or ObjectDisposedException or InvalidOperationException
                or System.Runtime.InteropServices.ExternalException or InvalidDataException
                or DecoderFallbackException)
            {
                // A disconnected, stalled or malformed peer never terminates the listener.
            }
            if (singleUse && claimed) return;
            if (!stopping.IsCancellationRequested) status("等待连接。每次请求都需在这里确认。", true);
        }
    }

    private async Task ServeOne(TcpClient tcp, CancellationToken stopping)
    {
        using var closeSocket = stopping.Register(() => tcp.Dispose());
        using var tls = new SslStream(tcp.GetStream());
        using (var deadline = CancellationTokenSource.CreateLinkedTokenSource(stopping))
        {
            deadline.CancelAfter(TimeSpan.FromSeconds(10));
            await tls.AuthenticateAsServerAsync(new SslServerAuthenticationOptions
            {
                ServerCertificate = certificate,
                EnabledSslProtocols = SslProtocols.Tls12 | SslProtocols.Tls13,
                ClientCertificateRequired = false
            }, deadline.Token);
            var (type, payload) = await ReadRecord(tls, 32, deadline.Token);
            if (type != 1 || !ValidSecret(payload))
            {
                await WriteRecord(tls, (byte)Access.Denied, [], deadline.Token);
                await Task.Delay(250, stopping);
                return;
            }
        }

        var remote = ((IPEndPoint?)tcp.Client.RemoteEndPoint)?.Address;
        if (remote?.IsIPv4MappedToIPv6 == true) remote = remote.MapToIPv4();
        string peer = remote?.ToString() ?? "未知地址";
        Access access = await confirm(peer, stopping);
        if (access != Access.Denied) claimed = true;
        using (var deadline = CancellationTokenSource.CreateLinkedTokenSource(stopping))
        {
            deadline.CancelAfter(TimeSpan.FromSeconds(5));
            await WriteRecord(tls, (byte)access, [], deadline.Token);
        }
        if (access == Access.Denied) return;

        status(access == Access.Control ? $"共享中 · {peer} 可控制桌面" : $"共享中 · {peer} 仅可观看", false);
        using var session = CancellationTokenSource.CreateLinkedTokenSource(stopping);
        // A failure, rejection, or disconnect on either side cuts off both input and output.
        var receive = Receive(tls, access, session.Token);
        var send = StreamDesktop(tls, session.Token);
        try { await Task.WhenAny(receive, send); }
        finally
        {
            session.Cancel();
            tcp.Dispose();
            await Task.WhenAll(receive, send);
        }
    }

    private bool ValidSecret(byte[] text)
    {
        if (text.Length != 32) return false;
        Span<byte> input = stackalloc byte[16];
        var result = Convert.FromHexString(Encoding.ASCII.GetString(text), input, out _, out int written);
        return result == System.Buffers.OperationStatus.Done && written == input.Length &&
            CryptographicOperations.FixedTimeEquals(input, secret);
    }

    private static async Task StreamDesktop(SslStream tls, CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            byte[] frame = Desktop.Frame();
            if (frame.Length > MaxFrame) throw new InvalidDataException("画面过大。");
            using (var deadline = CancellationTokenSource.CreateLinkedTokenSource(token))
            {
                deadline.CancelAfter(TimeSpan.FromSeconds(8));
                await WriteRecord(tls, 16, frame, deadline.Token);
            }
            await Task.Delay(125, token);
        }
    }

    private static async Task Receive(SslStream tls, Access access, CancellationToken token)
    {
        var clock = Stopwatch.StartNew();
        int count = 0;
        while (!token.IsCancellationRequested)
        {
            var (type, payload) = await ReadRecord(tls, 1024, token);
            if (type == 5 && payload.Length == 0) return;
            if (type is not (32 or 33 or 34 or 35)) throw new InvalidDataException("无效记录。");
            if (clock.ElapsedMilliseconds >= 1000) { count = 0; clock.Restart(); }
            if (++count > 300) throw new InvalidDataException("控制指令过于频繁。");
            token.ThrowIfCancellationRequested();
            if (access == Access.Control) Desktop.Apply(type, payload);
        }
    }

    private static async Task<(byte, byte[])> ReadRecord(SslStream tls, int maxBytes, CancellationToken token)
    {
        var header = new byte[5];
        // A passive viewer may send nothing for hours; cap time only after the first byte arrives.
        await tls.ReadExactlyAsync(header.AsMemory(0, 1), token);
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
        deadline.CancelAfter(TimeSpan.FromSeconds(5));
        await tls.ReadExactlyAsync(header.AsMemory(1), deadline.Token);
        uint size = BinaryPrimitives.ReadUInt32BigEndian(header.AsSpan(1));
        if (size > maxBytes) throw new InvalidDataException("超出记录大小。");
        byte[] payload = new byte[(int)size];
        if (size > 0) await tls.ReadExactlyAsync(payload, deadline.Token);
        return (header[0], payload);
    }

    private static async Task WriteRecord(SslStream tls, byte type, byte[] bytes, CancellationToken token)
    {
        byte[] header = new byte[5];
        header[0] = type;
        BinaryPrimitives.WriteUInt32BigEndian(header.AsSpan(1), (uint)bytes.Length);
        await tls.WriteAsync(header, token);
        if (bytes.Length > 0) await tls.WriteAsync(bytes, token);
    }

    public void Dispose()
    {
        listener.Stop();
        certificate.Dispose();
        CryptographicOperations.ZeroMemory(secret);
    }
}
