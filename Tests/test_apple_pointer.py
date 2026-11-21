"""Loopback checks for the production Apple viewer's negotiated pointer transport."""
import asyncio
import hashlib
from pathlib import Path
import secrets
import shutil
import ssl
import struct
import subprocess
import sys
import tempfile
import unittest

from test_relay import close, read_record, record, server_tls

ROOT = Path(__file__).resolve().parents[1]
ALPN = "nnremote-pointer/1"


def pointer(x, y, action):
    return 32, struct.pack("!HHB", x, y, action)


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("xcrun") and shutil.which("openssl"),
                     "requires macOS, Xcode Swift, and openssl")
class ApplePointerTests(unittest.IsolatedAsyncioTestCase):
    @classmethod
    def setUpClass(cls):
        directory = tempfile.TemporaryDirectory()
        cls.addClassCleanup(directory.cleanup)
        path = Path(directory.name)
        cls.executable = path / "pointer-client"
        cls.cert = path / "host.pem"
        cls.key = path / "host-key.pem"
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5", "-o", str(cls.executable),
            str(ROOT / "Apple/ViewerSources/ViewerTransport.swift"),
            str(ROOT / "Apple/ViewerSources/ViewerView.swift"),
            str(ROOT / "Tests/AppleViewerTransport/PointerClient.swift"),
        ], check=True, timeout=90)
        subprocess.run([
            "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
            "-subj", "/CN=nnremote Test Desktop", "-keyout", str(cls.key), "-out", str(cls.cert),
        ], check=True, capture_output=True, timeout=15)
        cls.pin = hashlib.sha256(ssl.PEM_cert_to_DER_cert(cls.cert.read_text())).hexdigest()

    async def exchange(self, enhanced, control):
        context = server_tls(self.cert, self.key)
        if enhanced:
            context.set_alpn_protocols([ALPN])
        secret = secrets.token_hex(16)
        captured = asyncio.get_running_loop().create_future()

        async def desktop(reader, writer):
            try:
                self.assertEqual(writer.get_extra_info("ssl_object").selected_alpn_protocol(),
                                 ALPN if enhanced else None)
                self.assertEqual(await read_record(reader), (1, secret.encode()))
                writer.write(record(3 if control else 2))
                await writer.drain()
                messages = []
                while True:
                    command = await read_record(reader)
                    if command == (5, b""):
                        captured.set_result(messages)
                        break
                    messages.append(command)
            except Exception as error:
                if not captured.done():
                    captured.set_exception(error)
            finally:
                await close(writer)

        server = await asyncio.start_server(desktop, "127.0.0.1", 0, ssl=context)
        async with server:
            port = server.sockets[0].getsockname()[1]
            client = await asyncio.create_subprocess_exec(
                str(self.executable), str(port), self.pin, secret,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            )
            try:
                stdout, stderr = await asyncio.wait_for(client.communicate(), 8)
                self.assertEqual(client.returncode, 0, stderr.decode(errors="replace"))
                self.assertEqual(stdout.decode().strip(),
                                 f"approved {str(control).lower()} {str(enhanced).lower()}")
                return await asyncio.wait_for(captured, 1)
            finally:
                if client.returncode is None:
                    client.kill()
                    await client.wait()
                if captured.done() and not captured.cancelled():
                    captured.exception()
                elif not captured.done():
                    captured.cancel()

    async def test_orders_edges_and_releases_held_button_on_stop(self):
        messages = await self.exchange(enhanced=True, control=True)
        self.assertEqual(messages[0], pointer(200, 300, 3))
        up = messages.index(pointer(1_201, 302, 4))
        moves = messages[1:up]
        self.assertTrue(moves)
        self.assertLess(len(moves), 100)
        self.assertTrue(all(kind == 32 and body[-1] == 0 for kind, body in moves))
        self.assertEqual(moves[-1], pointer(1_200, 301, 0))
        self.assertEqual(messages[up:], [
            pointer(1_201, 302, 4), pointer(1_202, 303, 1),
            (35, struct.pack("!HHh", 1_203, 304, -2)),
            pointer(1_204, 305, 5), pointer(1_204, 305, 6),
        ])

    async def test_falls_back_to_legacy_click_and_scroll(self):
        messages = await self.exchange(enhanced=False, control=True)
        self.assertEqual(messages[-2:], [pointer(1_202, 303, 1), (35, struct.pack("!HHh", 1_203, 304, -2))])
        self.assertEqual(messages[-3], pointer(1_200, 301, 0))
        self.assertTrue(all(kind == 32 and body[-1] == 0 for kind, body in messages[:-2]))

    async def test_view_only_does_not_send_input(self):
        self.assertEqual(await self.exchange(enhanced=True, control=False), [])

    def test_maps_aspect_fit_scaled_and_outside_coordinates(self):
        subprocess.run([str(self.executable), "geometry"], check=True, timeout=5)
