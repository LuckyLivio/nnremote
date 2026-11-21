using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.Drawing;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using LivioRemote.Windows;

namespace LivioRemote.WindowsHost;

// Supply only capture and OS input to the linked production transport.
internal static class Desktop
{
    public static readonly ConcurrentQueue<(byte Kind, byte[] Data)> Inputs = new();
    public static readonly ConcurrentQueue<string> PointerEvents = new();
    public static int FrameCount;
    public static readonly byte[] Jpeg = Convert.FromBase64String(
        "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRof" +
        "Hh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAACAAIBAREA/8QAFAAB" +
        "AAAAAAAAAAAAAAAAAAAAB//EACAQAAACCwAAAAAAAAAAAAAAAAUGAAECAwQVJTNEUmH/2gAIAQEA" +
        "AD8AXwssF+UwVCDLDGI71VxP/9k=");

    public static byte[] Frame()
    {
        Interlocked.Increment(ref FrameCount);
        return Jpeg;
    }

    public static void Apply(byte kind, byte[] data) => Inputs.Enqueue((kind, data));

    public static bool PositionPointer(byte[] data)
    {
        Apply(32, data);
        PointerEvents.Enqueue($"position:{data[4]}");
        return true;
    }

    public static bool SetMouseButton(PointerButton button, bool down)
    {
        PointerEvents.Enqueue($"{button}:{(down ? "down" : "up")}");
        return true;
    }
}

internal static class Program
{
    private static readonly SslApplicationProtocol PointerProtocol = new("nnremote-pointer/1");

    private static async Task Main()
    {
        TestPointerGeometry();
        TestPointerUpWithFailedPosition();
        await TestSharing(Access.View);
        await TestSharing(Access.Control);
        await TestPointer(Access.Control, offerPointer: true, stopHost: false);
        await TestPointer(Access.Control, offerPointer: true, stopHost: true);
        await TestPointer(Access.View, offerPointer: true, stopHost: false);
        await TestPointer(Access.Control, offerPointer: false, stopHost: false);
        await TestNewViewerWithLegacyHost();
        Console.WriteLine("Passed: real HostService TLS/auth/approval, frame transport, " +
            "view-only enforcement, protocol fallback, pointer geometry and ordering, and release on disconnect and stop.");
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static void TestPointerGeometry()
    {
        var image = new Size(800, 600);
        Check(!PointerGeometry.TryMap(new(1000, 600), image, new(99, 0), out _, out _, clamp: false),
            "pillarbox accepted a press");
        Check(PointerGeometry.TryMap(new(1000, 600), image, new(100, 0), out ushort x, out ushort y, clamp: false)
            && x == 0 && y == 0, "first visible pixel did not map to the origin");
        Check(!PointerGeometry.TryMap(new(800, 900), image, new(400, 149), out _, out _, clamp: false),
            "letterbox accepted a press in a portrait window");
        Check(PointerGeometry.TryMap(new(800, 900), image, new(-30, 915), out x, out y, clamp: true)
            && x == 0 && y == ushort.MaxValue, "out-of-frame release did not clamp to the visible video edge");
        Check(PointerGeometry.TryMap(new(1600, 1250), image, new(1599, 1224), out x, out y, clamp: false)
            && x == ushort.MaxValue && y == ushort.MaxValue, "scaled viewport did not map the last visible pixel");
    }

    private static void TestPointerUpWithFailedPosition()
    {
        var sent = new List<bool>();
        var pointer = new PointerSession(data => data[4] == 3, (_, down) => { sent.Add(down); return true; });
        pointer.Apply([0, 0, 0, 0, 3]);
        pointer.Apply([0, 0, 0, 0, 4]);
        pointer.ReleaseButtons();
        Check(sent.SequenceEqual(new[] { true, false }), "failed cursor positioning prevented or duplicated the release");
    }

    private static async Task TestPointer(Access scope, bool offerPointer, bool stopHost)
    {
        Desktop.Inputs.Clear();
        Desktop.PointerEvents.Clear();
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(20));
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(deadline.Token);
        CancellationToken token = deadline.Token;
        using var host = new HostService((_, _) => Task.FromResult(scope), (_, _) => { }, singleUse: true);
        Task serving = host.RunAsync(stop.Token);
        try
        {
            byte[] pin = Convert.FromHexString(host.Fingerprint.Replace(" ", ""));
            await WithTls(pin, async stream =>
            {
                Check(stream.NegotiatedApplicationProtocol == (offerPointer ? PointerProtocol : default),
                    "pointer ALPN does not match the client's offer");
                await Write(stream, 1, Encoding.ASCII.GetBytes(host.Secret), token);
                Check((await Read(stream, token)).Type == (byte)scope, "approval changed with negotiation");
                Check((await Read(stream, token)).Type == 16, "frame format changed with negotiation");

                // An unadvertised extension alone must not inject a button into the legacy session.
                byte[] actions = offerPointer ? [3, 0, 4, 5, 0, 6, 7, 3, 5] : [3];
                foreach (byte action in actions)
                    await Write(stream, 32, [0x12, 0x34, 0xab, 0xcd, action], token);

                if (!offerPointer || scope == Access.View)
                {
                    if (scope == Access.View) await Write(stream, 5, [], token);
                    await serving.WaitAsync(token);
                    return;
                }

                while (Desktop.PointerEvents.Count < 19) await Task.Delay(10, token);
                if (stopHost)
                {
                    stop.Cancel();
                    await serving.WaitAsync(token);
                }
                // Disposing the TLS stream without a button-up or close record simulates a lost controller.
            }, token, offerPointer);
            await serving.WaitAsync(token);

            string[] expected = offerPointer && scope == Access.Control
                ? ["position:3", "Left:down", "position:0", "position:4", "Left:up",
                   "position:5", "Right:down", "position:0", "position:6", "Right:up",
                   "position:7", "Left:down", "Left:up", "Left:down", "Left:up",
                   "position:3", "Left:down", "position:5", "Right:down", "Left:up", "Right:up"]
                : [];
            Check(Desktop.PointerEvents.SequenceEqual(expected), "unexpected pointer order or unreleased button");
        }
        finally { stop.Cancel(); }
    }

    private static async Task TestNewViewerWithLegacyHost()
    {
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(20));
        CancellationToken token = deadline.Token;
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        int port = ((IPEndPoint)listener.LocalEndpoint).Port;
        using var rsa = RSA.Create(2048);
        var request = new CertificateRequest("CN=127.0.0.1", rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        using var certificate = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddMinutes(-1), DateTimeOffset.UtcNow.AddMinutes(1));
        byte[] secret = RandomNumberGenerator.GetBytes(16);
        byte[] click = [1, 2, 3, 4, 1];

        async Task LegacyHost()
        {
            using var tcp = await listener.AcceptTcpClientAsync(token);
            using var tls = new SslStream(tcp.GetStream());
            await tls.AuthenticateAsServerAsync(new SslServerAuthenticationOptions
            {
                ServerCertificate = certificate,
                EnabledSslProtocols = SslProtocols.Tls12 | SslProtocols.Tls13
            }, token);
            var (type, payload) = await Read(tls, token);
            Check(type == 1 && payload.SequenceEqual(Encoding.ASCII.GetBytes(Convert.ToHexString(secret))),
                "viewer changed the legacy authentication record");
            await Write(tls, (byte)Access.Control, [], token);
            (type, payload) = await Read(tls, token);
            Check(type == 32 && payload.SequenceEqual(click), "viewer changed the legacy click record");
        }

        Task serving = LegacyHost();
        using var viewer = new ViewerLink();
        Check(await viewer.ConnectAsync("127.0.0.1", port, certificate.GetCertHash(HashAlgorithmName.SHA256), secret, () => { }),
            "new viewer did not connect to a legacy host");
        Check(viewer.MayControl && !viewer.ExtendedPointer, "viewer did not fall back to legacy control");
        bool rejected = false;
        try { await viewer.InputAsync(32, [1, 2, 3, 4, 3]); }
        catch (InvalidDataException) { rejected = true; }
        Check(rejected, "viewer accepted an extended action without negotiation");
        await viewer.InputAsync(32, click);
        await serving.WaitAsync(token);
    }

    private static async Task TestSharing(Access scope)
    {
        Desktop.Inputs.Clear();
        Desktop.FrameCount = 0;
        var ownerAsked = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var ownerDecision = new TaskCompletionSource<Access>(TaskCreationOptions.RunContinuationsAsynchronously);
        int approvalCount = 0;
        int sharingAnnouncements = 0;
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(20));
        CancellationToken token = deadline.Token;

        Task<Access> Confirm(string peer, CancellationToken cancellation)
        {
            Check(IPAddress.IsLoopback(IPAddress.Parse(peer)), "unexpected address in approval request");
            if (Interlocked.Increment(ref approvalCount) == 1) return Task.FromResult(Access.Denied);
            ownerAsked.TrySetResult();
            return ownerDecision.Task.WaitAsync(cancellation);
        }

        using (var host = new HostService(Confirm, (_, waiting) =>
               { if (!waiting) Interlocked.Increment(ref sharingAnnouncements); }, singleUse: true))
        {
            Task serving = host.RunAsync(token);
            try
            {
                byte[] pin = Convert.FromHexString(host.Fingerprint.Replace(" ", ""));
                byte[] invalidPin = (byte[])pin.Clone();
                invalidPin[0] ^= 0xff;
                bool rejectedPin = false;
                try
                {
                    await WithTls(invalidPin, stream => throw new InvalidOperationException(
                        "TLS unexpectedly trusted the wrong desktop certificate"), token);
                }
                catch (AuthenticationException) { rejectedPin = true; }
                Check(rejectedPin, "wrong pin should terminate TLS");
                Check(approvalCount == 0 && Desktop.FrameCount == 0, "unauthenticated peer triggered desktop access");

                byte[] tokenBytes = Convert.FromHexString(host.Secret);
                tokenBytes[0] ^= 0xff;
                await AssertDenied(pin, Convert.ToHexString(tokenBytes), token);
                Check(approvalCount == 0, "wrong secret reached the host's approval UI");
                await AssertDenied(pin, host.Secret, token);
                Check(approvalCount == 1 && Desktop.FrameCount == 0, "owner denial started a capture");

                var commands = new (byte Kind, byte[] Data)[]
                {
                    (32, [0x12, 0x34, 0xab, 0xcd, 2]),
                    (33, Encoding.UTF8.GetBytes("hello 远程")),
                    (34, [1]),
                    (35, [0x12, 0x34, 0xab, 0xcd, 0xff, 0xfd])
                };
                await WithTls(pin, async stream =>
                {
                    await Write(stream, 1, Encoding.ASCII.GetBytes(host.Secret.ToLowerInvariant()), token);
                    await ownerAsked.Task.WaitAsync(token);
                    Check(Desktop.FrameCount == 0 && sharingAnnouncements == 0,
                        "capture started while the owner had not yet approved");
                    ownerDecision.SetResult(scope);

                    var (reply, body) = await Read(stream, token);
                    Check(reply == (byte)scope && body.Length == 0, "unexpected approval result");
                    var (type, frame) = await Read(stream, token);
                    Check(type == 16 && frame.SequenceEqual(Desktop.Jpeg), "JPEG did not arrive intact");
                    foreach (var command in commands) await Write(stream, command.Kind, command.Data, token);
                    await Write(stream, 5, [], token);
                    // RunAsync returns by itself only when single-use sharing has been claimed and ended.
                    await serving.WaitAsync(token);
                }, token);
                Check(approvalCount == 2 && sharingAnnouncements == 1, "unexpected approval/session count");

                var inputs = Desktop.Inputs.ToArray();
                if (scope == Access.View)
                    Check(inputs.Length == 0, "view-only input leaked through the host");
                else
                {
                    Check(inputs.Length == commands.Length, "approved input was dropped or duplicated");
                    for (int i = 0; i < commands.Length; ++i)
                        Check(inputs[i].Kind == commands[i].Kind && inputs[i].Data.SequenceEqual(commands[i].Data),
                            "input opcode, order, or byte payload changed");
                }
            }
            finally
            {
                deadline.Cancel();
                try { await serving; }
                catch (OperationCanceledException) when (deadline.IsCancellationRequested) { }
            }
        }

        using var probe = new TcpClient();
        using var cleanupTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(2));
        try { await probe.ConnectAsync(IPAddress.Loopback, HostService.Port, cleanupTimeout.Token); }
        catch (SocketException exception) when (exception.SocketErrorCode == SocketError.ConnectionRefused) { return; }
        throw new InvalidOperationException("listener remained open after the host was disposed");
    }

    private static async Task AssertDenied(byte[] pin, string secret, CancellationToken token)
    {
        await WithTls(pin, async stream =>
        {
            await Write(stream, 1, Encoding.ASCII.GetBytes(secret), token);
            var (type, bytes) = await Read(stream, token);
            Check(type == (byte)Access.Denied && bytes.Length == 0, "expected an empty denial response");
        }, token);
    }

    private static async Task WithTls(byte[] pin, Func<SslStream, Task> action, CancellationToken token, bool offerPointer = false)
    {
        using var socket = new TcpClient();
        await socket.ConnectAsync(IPAddress.Loopback, HostService.Port, token);
        using var stream = new SslStream(socket.GetStream(), false, (_, certificate, _, _) =>
            certificate is not null && CryptographicOperations.FixedTimeEquals(
                SHA256.HashData(certificate.GetRawCertData()), pin));
        await stream.AuthenticateAsClientAsync(new SslClientAuthenticationOptions
        {
            TargetHost = "127.0.0.1",
            EnabledSslProtocols = SslProtocols.Tls12 | SslProtocols.Tls13,
            ApplicationProtocols = offerPointer ? [PointerProtocol] : null,
            CertificateRevocationCheckMode = X509RevocationMode.NoCheck
        }, token);
        await action(stream);
    }

    private static async Task Write(SslStream stream, byte type, byte[] data, CancellationToken token)
    {
        byte[] record = new byte[5 + data.Length];
        record[0] = type;
        BinaryPrimitives.WriteInt32BigEndian(record.AsSpan(1), data.Length);
        data.CopyTo(record, 5);
        await stream.WriteAsync(record, token);
    }

    private static async Task<(byte Type, byte[] Body)> Read(SslStream stream, CancellationToken token)
    {
        byte[] header = new byte[5];
        await stream.ReadExactlyAsync(header, token);
        int length = BinaryPrimitives.ReadInt32BigEndian(header.AsSpan(1));
        Check(length is >= 0 and <= 8 * 1024 * 1024, "invalid record length");
        byte[] body = new byte[length];
        if (length > 0) await stream.ReadExactlyAsync(body, token);
        return (header[0], body);
    }
}
