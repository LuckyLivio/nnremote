"""Livio Remote optional relay. Python 3.10+. Uses only the standard library.
The host-side link can reach only the local desktop application's fixed port.
"""
import argparse
import asyncio
import contextlib
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
import shutil
import ssl
import subprocess
import sys

HOST_PORT = 47831
BRIDGE_PORT = 47832
PUBLIC_PORT = 47833
HELLO = b"LivioLink1\n"


def create_config(folder):
    binary = shutil.which("openssl")
    if not binary:
        raise ValueError("初始化中继需要 OpenSSL。")
    folder = Path(folder)
    folder.mkdir(mode=0o700, parents=False, exist_ok=False)
    cert = folder / "relay.pem"
    pem_key = folder / "relay-key.pem"
    subprocess.run([binary, "req", "-x509", "-newkey", "rsa:3072", "-nodes",
                    "-subj", "/CN=Livio Relay", "-sha256", "-days", "365",
                    "-keyout", str(pem_key), "-out", str(cert)], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    os.chmod(pem_key, 0o600)
    der = ssl.PEM_cert_to_DER_cert(cert.read_text())
    info = {"relay_sha256": hashlib.sha256(der).hexdigest(), "link_key": secrets.token_hex(32)}
    fd = os.open(folder / "link.json", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as out:
        json.dump(info, out)
    print("中继配置已创建。仅将 link.json 私下交给共享电脑。relay-key.pem 留在中继服务器。")


def config(path):
    info = json.loads(Path(path).read_text(encoding="utf-8"))
    pin, key = (bytes.fromhex(info[k]) for k in ("relay_sha256", "link_key"))
    if len(pin) != 32 or len(key) != 32:
        raise ValueError("中继配置中的指纹或密钥长度无效。")
    return pin, key


async def exact(reader, size, seconds):
    return await asyncio.wait_for(reader.readexactly(size), timeout=seconds)


async def write(writer, data):
    writer.write(data)
    await asyncio.wait_for(writer.drain(), timeout=20)


async def close(writer):
    writer.close()
    with contextlib.suppress(Exception):
        await asyncio.wait_for(writer.wait_closed(), timeout=2)


async def exchange(left, right):
    async def copy(source, dest):
        while chunk := await source.read(65536):
            await write(dest, chunk)

    jobs = [asyncio.create_task(copy(left[0], right[1])), asyncio.create_task(copy(right[0], left[1]))]
    try:
        done, _ = await asyncio.wait(jobs, return_when=asyncio.FIRST_COMPLETED)
        for job in done:
            job.result()
    finally:
        for job in jobs:
            job.cancel()
        await asyncio.gather(*jobs, return_exceptions=True)


class Relay:
    def __init__(self, key):
        self.key = key
        self.idle = None
        self.active = False
        self.public_waiters = 0
        self.link_waiters = 0

    async def bridge(self, reader, writer):
        if self.link_waiters >= 8:
            await close(writer)
            return
        self.link_waiters += 1
        claimed = None
        try:
            frame = await exact(reader, len(HELLO) + 32, 6)
            if not frame.startswith(HELLO) or not hmac.compare_digest(frame[len(HELLO):], self.key):
                return
            if self.active or self.idle:
                return
            # The public handler owns both directions until its session ends.
            claimed = asyncio.get_running_loop().create_future()
            completed = asyncio.get_running_loop().create_future()
            self.idle = (reader, writer, claimed, completed)
            await write(writer, b"R")
            deadline = asyncio.get_running_loop().time() + 45
            while not claimed.done():
                if reader.at_eof() or writer.is_closing():
                    return
                if asyncio.get_running_loop().time() >= deadline:
                    self.idle = None
                    await write(writer, b"I")
                    return
                # Poll EOF without competing with the session's StreamReader.
                await asyncio.wait({claimed}, timeout=0.25)
            await completed
        except (EOFError, OSError, TimeoutError, asyncio.TimeoutError, ConnectionError):
            pass
        finally:
            if self.idle and self.idle[2] is claimed:
                self.idle = None
            self.link_waiters -= 1
            await close(writer)

    async def viewer(self, reader, writer):
        if self.public_waiters >= 8:
            await close(writer)
            return
        self.public_waiters += 1
        completed = None
        try:
            # A viewer always begins a TLS handshake with the desktop host.
            preface = await exact(reader, 5, 5)
            if (preface[0] != 22 or preface[1] != 3 or preface[2] not in (1, 2, 3)
                    or not 1 <= int.from_bytes(preface[3:], "big") <= 16384):
                return
            if self.active or self.idle is None or self.idle[2].done():
                return
            link_reader, link_writer, claimed, completed = self.idle
            self.idle = None
            self.active = True
            claimed.set_result(True)
            await write(link_writer, b"S")
            if await exact(link_reader, 1, 8) != b"Y":
                return
            await write(link_writer, preface)
            await exchange((reader, writer), (link_reader, link_writer))
        except (EOFError, OSError, TimeoutError, asyncio.TimeoutError, ConnectionError):
            pass
        finally:
            if completed is not None:
                self.active = False
                if not completed.done():
                    completed.set_result(True)
            self.public_waiters -= 1
            await close(writer)


async def serve(folder, bind, bridge_port, viewer_port):
    folder = Path(folder)
    _, key = config(folder / "link.json")
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.minimum_version = ssl.TLSVersion.TLSv1_2
    tls.load_cert_chain(folder / "relay.pem", folder / "relay-key.pem")
    relay = Relay(key)
    bridge = await asyncio.start_server(relay.bridge, bind, bridge_port, ssl=tls, ssl_handshake_timeout=6)
    async with bridge:
        viewers = await asyncio.start_server(relay.viewer, bind, viewer_port)
        async with viewers:
            print(f"中继已启动：共享电脑端口 {bridge_port}，观看端口 {viewer_port}。Ctrl+C 停止。", flush=True)
            await asyncio.gather(bridge.serve_forever(), viewers.serve_forever())


async def link_once(host, port, pin, key, announce):
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    tls.minimum_version = ssl.TLSVersion.TLSv1_2
    # The separately distributed certificate fingerprint is the trust anchor.
    tls.check_hostname = False
    tls.verify_mode = ssl.CERT_NONE
    reader, writer = await asyncio.wait_for(asyncio.open_connection(host, port, ssl=tls,
        server_hostname=host, ssl_handshake_timeout=7, happy_eyeballs_delay=0.25), timeout=15)
    try:
        cert = writer.get_extra_info("ssl_object").getpeercert(binary_form=True)
        if not cert or not hmac.compare_digest(hashlib.sha256(cert).digest(), pin):
            raise ValueError("中继指纹不匹配，已停止。请向中继所有者核对 link.json。")
        await write(writer, HELLO + key)
        if await exact(reader, 1, 8) != b"R":
            raise ConnectionError("中继尚未接受连接")
        announce()
        signal = await exact(reader, 1, 55)
        if signal == b"I":
            return  # Periodic idle reconnect keeps stale NAT mappings from lingering.
        if signal != b"S":
            raise ConnectionError("中继请求无效")
        try:
            local = await asyncio.wait_for(asyncio.open_connection("127.0.0.1", HOST_PORT), timeout=5)
        except OSError:
            await write(writer, b"N")
            return
        try:
            await write(writer, b"Y")
            await exchange((reader, writer), local)
        finally:
            await close(local[1])
    finally:
        await close(writer)


async def run_link(host, port, filename):
    pin, key = config(filename)
    status = None

    def say(message):
        nonlocal status
        if status != message:
            status = message
            print(message, flush=True)

    while True:
        try:
            await link_once(host, port, pin, key, lambda: say("已连接中继。请保持此窗口及桌面共享开启；Ctrl+C 退出。"))
        except (asyncio.IncompleteReadError, TimeoutError, asyncio.TimeoutError, OSError):
            say("正在重新连接中继…")
        await asyncio.sleep(1)


def main():
    parser = argparse.ArgumentParser(description="Livio Remote 私人中继")
    commands = parser.add_subparsers(dest="action", required=True)
    init = commands.add_parser("init", help="生成中继证书及密钥")
    init.add_argument("folder")
    service = commands.add_parser("serve", help="在你管理的服务器上启动中继")
    service.add_argument("folder")
    service.add_argument("--bind", default=None, help="默认监听可用 IPv4 和 IPv6")
    service.add_argument("--bridge-port", type=int, default=BRIDGE_PORT)
    service.add_argument("--viewer-port", type=int, default=PUBLIC_PORT)
    link = commands.add_parser("link", help="从共享桌面的电脑连接中继")
    link.add_argument("host")
    link.add_argument("config")
    link.add_argument("--bridge-port", type=int, default=BRIDGE_PORT)
    args = parser.parse_args()
    try:
        if args.action == "init":
            create_config(args.folder)
        elif args.action == "serve":
            asyncio.run(serve(args.folder, args.bind, args.bridge_port, args.viewer_port))
        else:
            asyncio.run(run_link(args.host, args.bridge_port, args.config))
    except KeyboardInterrupt:
        return
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as exc:
        print(f"无法启动：{exc}", file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
