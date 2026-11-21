using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;

namespace LivioRemote.WindowsHost;

// Supply only capture and OS input to the linked production transport.
internal static class Desktop
{
    public static readonly ConcurrentQueue<(byte Kind, byte[] Data)> Inputs = new();
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
}

internal static class Program
{
    private static async Task Main()
    {
        await TestSharing(Access.View);
        await TestSharing(Access.Control);
        Console.WriteLine("Passed: real HostService TLS/auth/approval, frame transport, " +
            "view-only enforcement, control dispatch, and single-use cleanup.");
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
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

    private static async Task WithTls(byte[] pin, Func<SslStream, Task> action, CancellationToken token)
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
