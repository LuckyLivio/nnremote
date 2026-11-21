import Foundation
import Network
import Security
import CryptoKit
import ImageIO
import CoreGraphics

enum ViewerEvent {
    case awaitingApproval
    case approved(control: Bool)
    case frame(CGImage)
    case ended(String)
}

struct ViewerEndpoint {
    let host: NWEndpoint.Host
    let port: NWEndpoint.Port
    let fingerprint: Data
    let secret: String
}

final class ViewerTransport {
    private enum Stage { case connecting, approval, streaming, ended }
    private let endpoint: ViewerEndpoint
    private let onEvent: (ViewerEvent) -> Void
    private let queue = DispatchQueue(label: "LivioRemote.Viewer")
    private var connection: NWConnection?
    private var timeout: DispatchSourceTimer?
    private var stage: Stage = .connecting
    private var canControl = false
    private var pinAccepted = false
    private var pinFailed = false
    private let maximumFrame = 8 * 1024 * 1024

    init(endpoint: ViewerEndpoint, onEvent: @escaping (ViewerEvent) -> Void) {
        self.endpoint = endpoint
        self.onEvent = onEvent
    }

    func start() {
        queue.async {
            guard self.stage == .connecting else { return }
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { [weak self] _, peerTrust, complete in
                guard let self = self else { complete(false); return }
                let trust = sec_trust_copy_ref(peerTrust).takeRetainedValue()
                let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate]
                guard let certificate = certificates?.first else {
                    self.pinFailed = true
                    complete(false)
                    return
                }
                let digest = Data(SHA256.hash(data: SecCertificateCopyData(certificate) as Data))
                let matches = digest == self.endpoint.fingerprint
                self.pinAccepted = matches
                self.pinFailed = !matches
                complete(matches)
            }, self.queue)

            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            let parameters = NWParameters(tls: tls, tcp: tcp)
            let connection = NWConnection(host: self.endpoint.host, port: self.endpoint.port, using: parameters)
            self.connection = connection

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.setEventHandler { [weak self] in
                guard let self = self else { return }
                switch self.stage {
                case .connecting: self.finish("连接超时，请核对主机地址、端口和网络。")
                case .approval: self.finish("等待主机确认超时。")
                case .streaming: self.finish("主机长时间未发送画面，连接已结束。")
                case .ended: break
                }
            }
            self.timeout = timer
            self.armTimeout(20)
            timer.resume()

            connection.stateUpdateHandler = { [weak self] state in
                guard let self = self, self.stage != .ended else { return }
                switch state {
                case .ready:
                    guard self.stage == .connecting else { return }
                    guard self.pinAccepted else { self.finish("未能校验主机证书，连接已取消。"); return }
                    self.stage = .approval
                    self.armTimeout(95)
                    self.deliver(.awaitingApproval)
                    self.write(1, Data(self.endpoint.secret.utf8))
                    self.readHeader()
                case .failed(let error):
                    self.finish(self.pinFailed ? "证书指纹不匹配。请与主机屏幕显示的指纹核对。" : "连接失败：\(error.localizedDescription)")
                case .cancelled: self.finish("连接已结束。")
                default: break
                }
            }
            connection.start(queue: self.queue)
        }
    }

    func stop() {
        queue.async {
            guard self.stage == .streaming, let connection = self.connection else {
                self.finish("已断开。")
                return
            }
            // Closing the transport also lets the host detect a disconnect if the end record is lost.
            let end = Self.record(5, Data())
            self.stage = .ended
            self.timeout?.cancel()
            self.timeout = nil
            self.connection = nil
            connection.stateUpdateHandler = nil
            connection.send(content: end, completion: .contentProcessed { _ in connection.cancel() })
            self.queue.asyncAfter(deadline: .now() + 1) { connection.cancel() }
        }
    }

    func pointer(x: UInt16, y: UInt16, action: UInt8) {
        var payload = Self.positionBytes(x, y)
        payload.append(action)
        sendInput(32, payload)
    }

    func scroll(x: UInt16, y: UInt16, ticks: Int16) {
        guard (1...10).contains(abs(Int(ticks))) else { return }
        let bits = UInt16(bitPattern: ticks)
        var payload = Self.positionBytes(x, y)
        payload.append(UInt8(bits >> 8))
        payload.append(UInt8(truncatingIfNeeded: bits))
        sendInput(35, payload)
    }

    private static func positionBytes(_ x: UInt16, _ y: UInt16) -> Data {
        Data([UInt8(x >> 8), UInt8(truncatingIfNeeded: x),
              UInt8(y >> 8), UInt8(truncatingIfNeeded: y)])
    }

    func sendText(_ text: String) {
        let bytes = Data(text.utf8)
        guard (1...1024).contains(bytes.count) else { return }
        sendInput(33, bytes)
    }

    func sendKey(_ code: UInt8) { sendInput(34, Data([code])) }

    private func sendInput(_ type: UInt8, _ payload: Data) {
        queue.async {
            guard self.stage == .streaming, self.canControl else { return }
            self.write(type, payload)
        }
    }

    private func armTimeout(_ seconds: Int) {
        timeout?.schedule(deadline: .now() + .seconds(seconds))
    }

    private func readHeader() {
        guard stage != .ended else { return }
        receiveExact(5) { [weak self] data in
            guard let self = self else { return }
            let bytes = [UInt8](data)
            let type = bytes[0]
            let length = bytes.dropFirst().reduce(0) { ($0 << 8) | Int($1) }
            switch (self.stage, type) {
            case (.approval, 2), (.approval, 3):
                guard length == 0 else { self.finish("主机授权消息格式错误。"); return }
                self.canControl = type == 3
                self.stage = .streaming
                self.armTimeout(30)
                self.deliver(.approved(control: self.canControl))
                self.readHeader()
            case (.approval, 4):
                self.finish(length == 0 ? "主机拒绝了请求，请核对配对密钥并请主机用户确认。" : "主机拒绝消息格式错误。")
            case (.streaming, 16):
                guard (1...self.maximumFrame).contains(length) else { self.finish("画面大小超出限制。"); return }
                self.receiveExact(length) { [weak self] payload in self?.display(payload) }
            case (_, 5):
                self.finish(length == 0 ? "主机已结束本次连接。" : "主机结束消息格式错误。")
            default:
                self.finish("主机发送了不支持的消息。")
            }
        }
    }

    private func display(_ data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == "public.jpeg",
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              (1...4096).contains(width), (1...4096).contains(height),
              width * height <= 1920 * 1080,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { finish("主机发送了无效或超大的 JPEG 画面。"); return }

        armTimeout(30)
        // Consume one frame at a time so a busy UI cannot accumulate decoded desktops.
        DispatchQueue.main.async {
            self.onEvent(.frame(image))
            self.queue.async { self.readHeader() }
        }
    }

    private func receiveExact(_ size: Int, completion: @escaping (Data) -> Void) {
        var received = Data()
        func next() {
            guard stage != .ended, let connection = connection else { return }
            let remaining = size - received.count
            connection.receive(minimumIncompleteLength: 1, maximumLength: min(remaining, 128 * 1024)) { [weak self] data, _, eof, error in
                guard let self = self, self.stage != .ended else { return }
                if let error = error {
                    self.finish("连接中断：\(error.localizedDescription)")
                    return
                }
                if let data = data { received.append(data) }
                if received.count == size { completion(received); return }
                if eof || data?.isEmpty != false { self.finish("主机已关闭连接。"); return }
                next()
            }
        }
        next()
    }

    private static func record(_ type: UInt8, _ payload: Data) -> Data {
        let n = UInt32(payload.count)
        var result = Data([type, UInt8(n >> 24), UInt8(truncatingIfNeeded: n >> 16),
                           UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)])
        result.append(payload)
        return result
    }

    private func write(_ type: UInt8, _ payload: Data) {
        connection?.send(content: Self.record(type, payload), completion: .contentProcessed { [weak self] error in
            if let error = error { self?.finish("发送失败：\(error.localizedDescription)") }
        })
    }

    private func deliver(_ event: ViewerEvent) {
        DispatchQueue.main.async { self.onEvent(event) }
    }

    private func finish(_ message: String) {
        guard stage != .ended else { return }
        stage = .ended
        timeout?.cancel()
        timeout = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        deliver(.ended(message))
    }
}
