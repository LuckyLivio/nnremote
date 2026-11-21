"""Loopback integration of the production link/relay with a reference desktop host and viewer.

Run with python -m unittest discover -s Tests -v. OpenSSL generates temporary certificates.
Stop any running Livio share on this machine before running the tests (TCP 47831).
"""
import asyncio
import base64
from contextlib import redirect_stdout, suppress
import hashlib
import importlib.util
import io
from pathlib import Path
import secrets
import shutil
import socket
import ssl
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch

RELAY_FILE = Path(__file__).resolve().parents[1] / "Link" / "relay.py"
spec = importlib.util.spec_from_file_location("livio_link_under_test", RELAY_FILE)
relay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(relay)

# Baseline 2x2 grayscale JPEG; no image library is needed to run the tests.
JPEG = base64.b64decode(
    "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRof"
    "Hh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAACAAIBAREA/8QAFAAB"
    "AAAAAAAAAAAAAAAAAAAAB//EACAQAAACCwAAAAAAAAAAAAAAAAUGAAECAwQVJTNEUmH/2gAIAQEA"
    "AD8AXwssF+UwVCDLDGI71VxP/9k="
)


def record(kind, payload=b""):
    return struct.pack("!BI", kind, len(payload)) + payload


async def read_record(reader):
    kind, length = struct.unpack("!BI", await asyncio.wait_for(reader.readexactly(5), 4))
    if length > 8 * 1024 * 1024:
        raise ValueError("record length exceeds desktop protocol limit")
    data = await asyncio.wait_for(reader.readexactly(length), 4)
    return kind, data


async def close(writer):
    writer.close()
    with suppress(OSError, TimeoutError, asyncio.TimeoutError):
        await asyncio.wait_for(writer.wait_closed(), 2)


def server_tls(chain, key):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(chain, key)
    return ctx


class TapReader:
    """Observe the bytes an actual production relay can read, after outer TLS decryption."""

    def __init__(self, source, capture):
        self.source = source
        self.capture = capture

    async def read(self, size):
        data = await self.source.read(size)
        self.capture.extend(data)
        return data


@unittest.skipUnless(shutil.which("openssl"), "requires openssl to issue temporary test certificates")
class RelayIntegrationTests(unittest.IsolatedAsyncioTestCase):
    @classmethod
    def setUpClass(cls):
        temporary = tempfile.TemporaryDirectory()
        cls.addClassCleanup(temporary.cleanup)
        directory = Path(temporary.name)
        with redirect_stdout(io.StringIO()):
            relay.create_config(directory / "relay")
        cls.relay_pin, cls.key = relay.config(directory / "relay" / "link.json")
        cls.relay_context = server_tls(directory / "relay" / "relay.pem", directory / "relay" / "relay-key.pem")

        cert = directory / "host.pem"
        key = directory / "host-key.pem"
        subprocess.run(
            [shutil.which("openssl"), "req", "-x509", "-newkey", "rsa:2048", "-nodes",
             "-days", "1", "-subj", "/CN=Livio Test Desktop", "-keyout", str(key), "-out", str(cert)],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE
        )
        cls.host_context = server_tls(cert, key)
        cls.host_pin = hashlib.sha256(ssl.PEM_cert_to_DER_cert(cert.read_text())).digest()
        if cls.host_pin == cls.relay_pin:
            raise AssertionError("test must use independent desktop and relay identities")

    async def asyncSetUp(self):
        self.secret = secrets.token_hex(16).upper().encode("ascii")
        self.host_messages = asyncio.Queue()
        self.relay = relay.Relay(self.key)
        self.servers = []
        self.tasks = set()
        self.links = []
        self.viewers = []
        self.uplink = bytearray()
        self.downlink = bytearray()
        self.addAsyncCleanup(self.cleanup_sockets)
        await self.listen(self.desktop, "127.0.0.1", relay.HOST_PORT, self.host_context)
        self.bridge_port = await self.listen(self.relay.bridge, "127.0.0.1", 0, self.relay_context)
        self.viewer_port = await self.listen(self.relay.viewer, "127.0.0.1", 0)

        original_exchange = relay.exchange

        async def observe_exchange(left, right):
            if left[1].get_extra_info("sockname")[1] == self.viewer_port:
                left = (TapReader(left[0], self.uplink), left[1])
                right = (TapReader(right[0], self.downlink), right[1])
            return await original_exchange(left, right)

        self.patcher = patch.object(relay, "exchange", new=observe_exchange)
        self.patcher.start()
        self.addCleanup(self.patcher.stop)

    async def listen(self, handler, host, port, context=None):
        async def tracked(r, w):
            task = asyncio.current_task()
            self.tasks.add(task)
            try:
                await handler(r, w)
            finally:
                self.tasks.discard(task)

        server = await asyncio.start_server(tracked, host, port, ssl=context)
        self.servers.append(server)
        return server.sockets[0].getsockname()[1]

    async def cleanup_sockets(self):
        for server in self.servers:
            server.close()
            await server.wait_closed()
        for writer in self.viewers:
            if not writer.is_closing():
                writer.transport.abort()
        remaining = [task for task in (*self.links, *self.tasks) if not task.done()]
        for task in remaining:
            task.cancel()
        await asyncio.gather(*remaining, return_exceptions=True)

    async def desktop(self, reader, writer):
        messages = []
        try:
            message = await read_record(reader)
            messages.append(message)
            if message != (1, self.secret):
                writer.write(record(4))
                await writer.drain()
                return
            writer.write(record(3) + record(16, JPEG))
            await writer.drain()
            while True:
                message = await read_record(reader)
                messages.append(message)
                if message == (5, b""):
                    return
        except (asyncio.IncompleteReadError, OSError):
            pass
        finally:
            await self.host_messages.put(messages)
            await close(writer)

    async def register_link(self):
        ready = asyncio.Event()
        task = asyncio.create_task(relay.link_once("127.0.0.1", self.bridge_port, self.relay_pin, self.key, ready.set))
        self.links.append(task)
        await asyncio.wait_for(ready.wait(), 5)
        return task

    async def viewer(self, ip, port, pin):
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        tls.minimum_version = ssl.TLSVersion.TLSv1_2
        tls.check_hostname = False
        tls.verify_mode = ssl.CERT_NONE
        reader, writer = await asyncio.wait_for(
            asyncio.open_connection(ip, port, ssl=tls, server_hostname=ip, ssl_handshake_timeout=4), 5)
        self.viewers.append(writer)
        der = writer.get_extra_info("ssl_object").getpeercert(binary_form=True)
        if not secrets.compare_digest(hashlib.sha256(der).digest(), pin):
            await close(writer)
            raise ssl.SSLError("wrong desktop pin")
        return reader, writer

    async def exchange_desktop(self, ip, port):
        reader, writer = await self.viewer(ip, port, self.host_pin)
        text = "会议记录：仅在端点中显示 / Livio private desktop".encode()
        pointer = struct.pack("!HHB", 1234, 65432, 2)
        scroll = struct.pack("!HHh", 32768, 65535, -3)
        # Split the authentication header to exercise TCP fragmentation.
        hello = record(1, self.secret)
        writer.write(hello[:2])
        await writer.drain()
        await asyncio.sleep(0)
        writer.write(hello[2:])
        await writer.drain()
        self.assertEqual(await read_record(reader), (3, b""))
        self.assertEqual(await read_record(reader), (16, JPEG))
        commands = [(32, pointer), (33, text), (34, bytes([1])), (35, scroll), (5, b"")]
        writer.write(b"".join(record(kind, body) for kind, body in commands))
        await writer.drain()
        observed = await asyncio.wait_for(self.host_messages.get(), 5)
        self.assertEqual(observed, [(1, self.secret), *commands])
        await close(writer)
        return text

    async def wait_link(self, task):
        await asyncio.wait_for(task, 5)
        for _ in range(100):
            if not self.relay.active and self.relay.link_waiters == 0:
                return
            await asyncio.sleep(0.01)
        self.fail("previous relay session was not released")

    async def test_relay_preserves_inner_tls_and_protocol(self):
        task = await self.register_link()
        text = await self.exchange_desktop("127.0.0.1", self.viewer_port)
        await self.wait_link(task)
        self.assertGreater(len(self.uplink), len(text))
        self.assertGreater(len(self.downlink), len(JPEG))
        self.assertNotIn(self.secret, self.uplink)
        self.assertNotIn(text, self.uplink)
        self.assertNotIn(JPEG, self.downlink)

    async def test_wrong_relay_pin_and_link_key(self):
        def never_ready():
            self.fail("an invalid link reached the ready state")

        with self.assertRaisesRegex(ValueError, "指纹"):
            await asyncio.wait_for(relay.link_once("127.0.0.1", self.bridge_port, self.host_pin, self.key, never_ready), 5)
        with self.assertRaises((asyncio.IncompleteReadError, ConnectionError)):
            await asyncio.wait_for(relay.link_once("127.0.0.1", self.bridge_port, self.relay_pin, b"\0" * 32, never_ready), 5)
        self.assertIsNone(self.relay.idle)
        self.assertTrue(self.host_messages.empty())

    async def test_duplicate_link_preserves_original(self):
        first = await self.register_link()
        with self.assertRaises((asyncio.IncompleteReadError, ConnectionError)):
            await asyncio.wait_for(relay.link_once("127.0.0.1", self.bridge_port, self.relay_pin,
                self.key, lambda: self.fail("duplicate link accepted")), 5)
        await self.exchange_desktop("127.0.0.1", self.viewer_port)
        await self.wait_link(first)

    async def test_relay_certificate_cannot_authenticate_desktop(self):
        task = await self.register_link()
        with self.assertRaisesRegex(ssl.SSLError, "wrong desktop pin"):
            await self.viewer("127.0.0.1", self.viewer_port, self.relay_pin)
        self.assertEqual(await asyncio.wait_for(self.host_messages.get(), 5), [])
        await self.wait_link(task)

    async def test_idle_link_cancellation_allows_new_link(self):
        first = await self.register_link()
        first.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await asyncio.wait_for(first, 5)
        for _ in range(100):
            if self.relay.idle is None and self.relay.link_waiters == 0:
                break
            await asyncio.sleep(0.025)
        self.assertIsNone(self.relay.idle, "a closed idle link blocks the next valid host")
        second = await self.register_link()
        await self.exchange_desktop("127.0.0.1", self.viewer_port)
        await self.wait_link(second)

    async def test_viewer_abort_allows_next_session(self):
        first = await self.register_link()
        reader, writer = await self.viewer("127.0.0.1", self.viewer_port, self.host_pin)
        writer.write(record(1, self.secret))
        await writer.drain()
        self.assertEqual(await read_record(reader), (3, b""))
        self.assertEqual(await read_record(reader), (16, JPEG))
        writer.transport.abort()
        self.assertEqual(await asyncio.wait_for(self.host_messages.get(), 5), [(1, self.secret)])
        await self.wait_link(first)
        second = await self.register_link()
        await self.exchange_desktop("127.0.0.1", self.viewer_port)
        await self.wait_link(second)

    async def test_wrong_desktop_secret_is_denied(self):
        task = await self.register_link()
        reader, writer = await self.viewer("127.0.0.1", self.viewer_port, self.host_pin)
        wrong = b"0" * 32
        writer.write(record(1, wrong))
        await writer.drain()
        self.assertEqual(await read_record(reader), (4, b""))
        self.assertEqual(await asyncio.wait_for(reader.read(1), 5), b"")
        self.assertEqual(await asyncio.wait_for(self.host_messages.get(), 5), [(1, wrong)])
        await close(writer)
        await self.wait_link(task)

    async def test_direct_ipv4(self):
        await self.exchange_desktop("127.0.0.1", relay.HOST_PORT)

    async def test_direct_ipv6_and_ipv6_viewer_to_ipv4_link(self):
        if not socket.has_ipv6:
            self.skipTest("IPv6 unavailable")
        try:
            direct_port = await self.listen(self.desktop, "::1", 0, self.host_context)
        except OSError as exc:
            self.skipTest(f"IPv6 loopback unavailable: {exc}")
        await self.exchange_desktop("::1", direct_port)
        await self.listen(self.relay.viewer, "::1", self.viewer_port)
        link = await self.register_link()
        await self.exchange_desktop("::1", self.viewer_port)
        await self.wait_link(link)


if __name__ == "__main__":
    unittest.main()
