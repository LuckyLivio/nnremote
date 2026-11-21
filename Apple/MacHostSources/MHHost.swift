#if os(macOS)
import ApplicationServices
import AppKit
import Foundation
import Network
import Security
import SwiftUI

private final class MHPeer {
    let link: NWConnection
    var desktop: MHDesktop?
    var control = false
    var pointerEdges = false
    var singleUse = false
    var reader: Task<Void, Never>?
    var stream: Task<Void, Never>?
    var deadline: DispatchWorkItem?
    private var inputWindow = ProcessInfo.processInfo.systemUptime
    private var commands = 0
    private var textBytes = 0

    init(_ link: NWConnection) { self.link = link }

    func checkInputRate(_ type: UInt8, bytes: Int) throws {
        let now = ProcessInfo.processInfo.systemUptime
        if now - inputWindow >= 1 {
            inputWindow = now
            commands = 0
            textBytes = 0
        }
        commands += 1
        if type == 33 { textBytes += bytes }
        guard commands <= 240 && textBytes <= 2048 else {
            throw MHError.detail("远程输入过于频繁，已断开连接。")
        }
    }

    func record() async throws -> (UInt8, Data) {
        let h = Array(try await read(5))
        let length = h[1...4].reduce(0) { ($0 << 8) | Int($1) }
        let valid: Bool
        switch h[0] {
        case 1: valid = length == 32
        case 5: valid = length == 0
        case 32: valid = length == 5
        case 33: valid = (1...1024).contains(length)
        case 34: valid = length == 1
        case 35: valid = length == 6
        default: valid = false
        }
        guard valid else { throw MHError.detail("连接数据格式错误。") }
        return (h[0], try await read(length))
    }

    private func read(_ length: Int) async throws -> Data {
        var result = Data()
        while result.count < length {
            let remaining = length - result.count
            let piece: Data = try await withCheckedThrowingContinuation { continuation in
                link.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, _, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: MHError.detail("对方已断开。")) }
                }
            }
            result.append(piece)
        }
        return result
    }

    func send(_ type: UInt8, _ payload: Data = Data()) async throws {
        let n = payload.count
        var record = Data([type, UInt8(truncatingIfNeeded: n >> 24), UInt8(truncatingIfNeeded: n >> 16),
                           UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)])
        record.append(payload)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            link.send(content: record, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}

@MainActor
final class MHHost: ObservableObject {
    @Published private(set) var listening = false
    @Published private(set) var ready = false
    @Published private(set) var pending = false
    @Published private(set) var busy = false
    @Published private(set) var status = "共享已关闭"
    @Published private(set) var addresses = [String]()
    @Published private(set) var pin = ""
    @Published private(set) var secret = ""
    @Published private(set) var preapprovalExpiry: Date?
    @Published private(set) var preapprovedControl = false
    private var listener: NWListener?
    private var credentials: MHIdentity?
    private var peer: MHPeer?
    private var expiryTimer: DispatchWorkItem?

    func start() {
        guard !listening else { return }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            status = "请到系统设置的「隐私与安全性」中允许屏幕录制，再退出并重新打开 App。"
            return
        }
        do {
            let id = try MHIdentity()
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, id.identity)
            sec_protocol_options_set_peer_authentication_required(tls.securityProtocolOptions, false)
            sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, PointerProtocol.name)
            let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
            let server = try NWListener(using: params, on: 47831)
            credentials = id
            pin = id.fingerprint
            secret = MHIdentity.hex(id.secret)
            addresses = MHAddresses()
            listening = true
            status = "正在打开监听端口…"
            listener = server
            server.stateUpdateHandler = { [weak self, weak server] state in
                Task { @MainActor in
                    guard let self, let server, self.listener === server else { return }
                    switch state {
                    case .ready:
                        self.ready = true
                        self.status = "等待连接"
                    case .failed(let error): self.close(error.localizedDescription)
                    default: break
                    }
                }
            }
            server.newConnectionHandler = { [weak self, weak server] link in
                Task { @MainActor in
                    guard let self, let server, self.listener === server else { link.cancel(); return }
                    self.accept(link)
                }
            }
            server.start(queue: .main)
        } catch { close(error.localizedDescription) }
    }

    func close(_ message: String = "共享已关闭") {
        let server = listener
        listener = nil
        server?.cancel()
        disarm()
        if let p = peer {
            p.singleUse = false
            finish(p, message)
        }
        credentials = nil
        pin = ""
        secret = ""
        addresses = []
        ready = false
        listening = false
        status = message
    }

    func arm(control: Bool) {
        guard ready, peer == nil, var id = credentials else { return }
        guard !control || accessibility() else { return }
        // Old invitations must never acquire new unattended permissions.
        do { try id.refreshSecret() } catch { close(error.localizedDescription); return }
        credentials = id
        secret = MHIdentity.hex(id.secret)
        disarm()
        preapprovedControl = control
        preapprovalExpiry = Date().addingTimeInterval(8 * 60 * 60)
        let expiry = DispatchWorkItem { [weak self] in
            guard let self, self.preapprovalExpiry != nil else { return }
            self.close("单次授权已到期，共享已关闭")
        }
        expiryTimer = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + 8 * 60 * 60, execute: expiry)
    }

    private func disarm() {
        expiryTimer?.cancel()
        expiryTimer = nil
        preapprovalExpiry = nil
        preapprovedControl = false
    }

    private func accessibility() -> Bool {
        guard AXIsProcessTrusted() else {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
            status = "请在「辅助功能」允许此 App 后重新点击授权，也可选择仅观看。"
            return false
        }
        return true
    }

    private func accept(_ link: NWConnection) {
        guard peer == nil, let id = credentials else { link.cancel(); return }
        let p = MHPeer(link)
        peer = p
        busy = true
        status = "正在验证连接"
        timeout(p, seconds: 12)
        link.stateUpdateHandler = { [weak self, weak p] state in
            Task { @MainActor in
                guard let self, let p, self.peer === p else { return }
                if case .failed(let error) = state { self.finish(p, error.localizedDescription) }
            }
        }
        link.start(queue: .main)
        p.reader = Task { [weak self, weak p] in
            guard let self, let p else { return }
            do {
                let (type, data) = try await p.record()
                guard self.peer === p else { return }
                guard type == 1, id.accepts(data) else {
                    try? await p.send(4)
                    self.finish(p, "配对口令无效")
                    return
                }
                p.pointerEdges = PointerProtocol.isNegotiated(on: p.link)
                if let expiry = self.preapprovalExpiry {
                    guard Date() < expiry else { self.close("单次授权已到期"); return }
                    let control = self.preapprovedControl
                    self.disarm()
                    p.singleUse = true
                    self.begin(p, control: control)
                } else {
                    self.pending = true
                    self.status = "连接请求 · \(link.endpoint)"
                    self.timeout(p, seconds: 60)
                    NSApp.requestUserAttention(.informationalRequest)
                }
                while self.peer === p {
                    let (command, body) = try await p.record()
                    guard self.peer === p else { return }
                    if command == 5 { self.finish(p, "对方已断开"); return }
                    guard let display = p.desktop, p.control else {
                        throw MHError.detail("连接发送了未经授权的控制指令。")
                    }
                    try p.checkInputRate(command, bytes: body.count)
                    try display.apply(type: command, payload: body, pointerEdges: p.pointerEdges)
                }
            } catch { self.finish(p, error.localizedDescription) }
        }
    }

    func decide(control: Bool) {
        guard pending, let p = peer else { return }
        guard !control || accessibility() else { return }
        begin(p, control: control)
    }

    func deny() {
        guard pending, let p = peer else { return }
        pending = false
        timeout(p, seconds: 2)
        Task {
            try? await p.send(4)
            finish(p, "已拒绝此连接")
        }
    }

    private func begin(_ p: MHPeer, control: Bool) {
        pending = false
        status = "正在准备桌面"
        timeout(p, seconds: 20)
        p.stream = Task { [weak self, weak p] in
            guard let self, let p else { return }
            do {
                guard !control || AXIsProcessTrusted() else { throw MHError.detail("辅助功能授权已撤销。") }
                let display = try await MHDesktop.open()
                guard self.peer === p else { return }
                p.desktop = display
                p.control = control
                try await p.send(control ? 3 : 2)
                guard self.peer === p else { return }
                self.status = (control ? "已允许控制" : "正在共享画面") + " · " + String(describing: p.link.endpoint)
                while self.peer === p {
                    guard !control || AXIsProcessTrusted() else { throw MHError.detail("辅助功能授权已撤销。") }
                    // Bound a stalled capture or send, even if the viewer stops reading.
                    self.timeout(p, seconds: 20)
                    let frame = try await display.frame()
                    guard self.peer === p else { return }
                    try await p.send(16, frame)
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
            } catch { self.finish(p, error.localizedDescription) }
        }
    }

    private func timeout(_ p: MHPeer, seconds: Int) {
        p.deadline?.cancel()
        let work = DispatchWorkItem { [weak self, weak p] in
            guard let self, let p else { return }
            self.finish(p, "连接已超时")
        }
        p.deadline = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds), execute: work)
    }

    private func finish(_ p: MHPeer, _ reason: String) {
        guard peer === p else { return }
        p.control = false
        p.desktop?.releasePointerButtons()
        peer = nil
        p.deadline?.cancel()
        p.reader?.cancel()
        p.stream?.cancel()
        p.link.cancel()
        busy = false
        pending = false
        if p.singleUse {
            close(reason + "。单次授权已结束。")
        } else {
            status = reason + (listener == nil ? "" : "。等待连接。")
        }
    }
}
#endif
