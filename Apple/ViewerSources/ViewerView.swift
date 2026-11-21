import SwiftUI
import Network
import CoreGraphics

private final class ViewerModel: ObservableObject {
    @Published var host = ""
    @Published var port = "47831"
    @Published var fingerprint = ""
    @Published var secret = ""
    @Published private(set) var message = ""
    @Published private(set) var connecting = false
    @Published private(set) var viewing = false
    @Published private(set) var canControl = false
    @Published private(set) var frame: CGImage?

    private var session: ViewerTransport?
    private var generation = UUID()
    private var pointerPosition: (x: UInt16, y: UInt16) = (32768, 32768)

    func connect() {
        guard !connecting, !viewing else { return }
        var address = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.hasPrefix("["), address.hasSuffix("]") {
            address = String(address.dropFirst().dropLast())
        }
        guard Self.isValidHost(address)
        else { message = "请填写主机的 IP 地址或主机名。"; return }

        guard let number = Self.portNumber(port.trimmingCharacters(in: .whitespacesAndNewlines)),
              let endpointPort = NWEndpoint.Port(rawValue: number)
        else { message = "端口应在 1 到 65535 之间。"; return }
        let pinSeparators = CharacterSet(charactersIn: ":-").union(.whitespacesAndNewlines)
        let pin = fingerprint.components(separatedBy: pinSeparators).joined()
        guard let digest = Self.hexBytes(pin, byteCount: 32)
        else { message = "请从主机复制完整的 64 位十六进制证书指纹。"; return }
        let pairing = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.hexBytes(pairing, byteCount: 16) != nil
        else { message = "配对密钥应为主机显示的 32 位十六进制字符。"; return }

        let endpoint = ViewerEndpoint(host: NWEndpoint.Host(address), port: endpointPort,
                                      fingerprint: digest, secret: pairing.uppercased())
        let id = UUID()
        generation = id
        connecting = true
        message = "正在建立加密连接并核对主机指纹…"
        let transport = ViewerTransport(endpoint: endpoint) { [weak self] event in
            guard let self = self, self.generation == id else { return }
            switch event {
            case .awaitingApproval:
                self.message = "已核对主机身份，等待主机确认…"
            case .approved(let control):
                self.connecting = false
                self.viewing = true
                self.canControl = control
                self.secret = ""
                self.message = "正在等待首帧…"
            case .frame(let image):
                self.frame = image
            case .ended(let reason):
                self.reset(reason)
            }
        }
        session = transport
        transport.start()
    }

    func disconnect() {
        session?.stop()
        reset("已断开。")
    }

    private func reset(_ reason: String) {
        generation = UUID()
        session = nil
        frame = nil
        pointerPosition = (32768, 32768)
        connecting = false
        viewing = false
        canControl = false
        message = reason
    }

    deinit { session?.stop() }

    func pointer(at point: CGPoint, in size: CGSize, action: UInt8) {
        guard canControl, frame != nil, size.width > 0, size.height > 0 else { return }
        func normalized(_ value: CGFloat, _ extent: CGFloat) -> UInt16 {
            UInt16((max(0, min(1, value / extent)) * 65535).rounded())
        }
        pointerPosition = (normalized(point.x, size.width), normalized(point.y, size.height))
        session?.pointer(x: pointerPosition.x, y: pointerPosition.y, action: action)
    }

    func scroll(_ ticks: Int16) {
        guard canControl, frame != nil else { return }
        session?.scroll(x: pointerPosition.x, y: pointerPosition.y, ticks: ticks)
    }

    func sendText(_ text: String) { if canControl { session?.sendText(text) } }
    func sendKey(_ key: UInt8) { if canControl { session?.sendKey(key) } }

    func importInvitation(_ raw: String) {
        guard !connecting, !viewing else { return }
        let invalid = "邀请格式有误，请让主机重新复制完整的邀请。"
        guard raw.utf8.count <= 512 else { message = invalid; return }
        let fields = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "|")
        guard fields.count == 5, fields[0] == "LRV1",
              Self.isValidHost(fields[1]), let number = Self.portNumber(fields[2]),
              Self.hexBytes(fields[3], byteCount: 32) != nil,
              Self.hexBytes(fields[4], byteCount: 16) != nil
        else { message = invalid; return }
        host = fields[1]
        port = String(number)
        fingerprint = fields[3].uppercased()
        secret = fields[4].uppercased()
        message = "已填入邀请，请核对主机信息后请求连接。"
    }

    private static func portNumber(_ text: String) -> UInt16? {
        guard (1...5).contains(text.utf8.count), text.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = UInt16(text), value > 0 else { return nil }
        return value
    }

    private static func isValidHost(_ address: String) -> Bool {
        guard (1...253).contains(address.utf8.count) else { return false }
        func letterOrDigit(_ byte: UInt8) -> Bool {
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
        }
        if address.contains(":") {
            let parts = address.components(separatedBy: "%")
            guard parts.count <= 2, IPv6Address(parts[0]) != nil else { return false }
            if parts.count == 1 { return true }
            let zone = parts[1].utf8
            return (1...64).contains(zone.count) && zone.allSatisfy {
                letterOrDigit($0) || $0 == 45 || $0 == 46 || $0 == 95
            }
        }
        if IPv4Address(address) != nil { return true }
        // Reject malformed dotted IPv4 literals before accepting DNS label syntax.
        if address.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) { return false }
        let dns = address.hasSuffix(".") ? String(address.dropLast()) : address
        return dns.components(separatedBy: ".").allSatisfy { label in
            let bytes = label.utf8
            return (1...63).contains(bytes.count) && bytes.first != 45 && bytes.last != 45
                && bytes.allSatisfy { letterOrDigit($0) || $0 == 45 }
        }
    }

    private static func hexBytes(_ input: String, byteCount: Int) -> Data? {
        let bytes = Array(input.utf8)
        guard bytes.count == byteCount * 2 else { return nil }
        func nibble(_ x: UInt8) -> UInt8? {
            switch x {
            case 48...57: return x - 48
            case 65...70: return x - 55
            case 97...102: return x - 87
            default: return nil
            }
        }
        var result = Data()
        for i in stride(from: 0, to: bytes.count, by: 2) {
            guard let a = nibble(bytes[i]), let b = nibble(bytes[i + 1]) else { return nil }
            result.append((a << 4) | b)
        }
        return result
    }
}

struct ViewerView: View {
    @StateObject private var model = ViewerModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var action: UInt8 = 1
    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            if model.viewing { desktop } else { connectionForm }
        }
        #if os(iOS)
        .onChange(of: scenePhase) { phase in
            if phase == .background && (model.viewing || model.connecting) { model.disconnect() }
        }
        #endif
        .onChange(of: model.viewing) { viewing in
            if !viewing { text = ""; action = 1 }
        }
    }

    private var connectionForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("连接电脑").font(.largeTitle.bold())
                HStack {
                    Text("主机邀请").font(.headline)
                    Spacer()
                    PasteButton(payloadType: String.self) { values in
                        if let value = values.first { model.importInvitation(value) }
                    }
                    .accessibilityLabel("粘贴主机邀请")
                }.disabled(model.connecting)
                VStack(alignment: .leading, spacing: 8) {
                    Text("主机地址").font(.headline)
                    HStack {
                        TextField("IPv4、IPv6 或主机名", text: $model.host)
                            .accessibilityLabel("主机地址")
                        TextField("端口", text: $model.port)
                            .frame(width: 76)
                            .accessibilityLabel("端口")
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                    }
                }.disabled(model.connecting)
                VStack(alignment: .leading, spacing: 8) {
                    Text("证书指纹").font(.headline)
                    TextField("主机显示的 SHA-256 指纹", text: $model.fingerprint)
                        .accessibilityLabel("证书指纹")
                    Text("在主机屏幕上核对，或请对方通过可信渠道发给你。")
                        .font(.footnote).foregroundStyle(.secondary)
                }.disabled(model.connecting)
                VStack(alignment: .leading, spacing: 8) {
                    Text("配对密钥").font(.headline)
                    SecureField("32 位十六进制密钥", text: $model.secret)
                        .accessibilityLabel("配对密钥")
                        .privacySensitive()
                }.disabled(model.connecting)
                if !model.message.isEmpty {
                    HStack {
                        if model.connecting { ProgressView().controlSize(.small) }
                        Text(model.message).font(.callout).foregroundStyle(.secondary)
                    }
                }
                if model.connecting {
                    Button("取消连接") { model.disconnect() }.buttonStyle(.bordered)
                } else {
                    Button("请求连接") { model.connect() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            }
            .textFieldStyle(.roundedBorder)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            #endif
            .padding(24)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var desktop: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.host).font(.headline).lineLimit(1)
                    Text(model.canControl ? "已允许控制" : "仅查看").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("断开", role: .destructive) { model.disconnect() }.buttonStyle(.bordered)
            }
            .padding(.horizontal).padding(.vertical, 6)

            GeometryReader { geometry in
                ZStack {
                    Color.black
                    if let image = model.frame, geometry.size.width > 0, geometry.size.height > 0 {
                        let scale = min(geometry.size.width / CGFloat(image.width),
                                        geometry.size.height / CGFloat(image.height))
                        let size = CGSize(width: CGFloat(image.width) * scale,
                                          height: CGFloat(image.height) * scale)
                        Image(decorative: image, scale: 1, orientation: .up)
                            .resizable()
                            .frame(width: size.width, height: size.height)
                            .contentShape(Rectangle())
                            .gesture(SpatialTapGesture().onEnded { value in
                                model.pointer(at: value.location, in: size, action: action)
                            })
                            .accessibilityLabel("远程桌面画面")
                    } else {
                        ProgressView(model.message).tint(.white).foregroundStyle(.white)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }

            if model.canControl {
                VStack(spacing: 7) {
                    Picker("点击画面时", selection: $action) {
                        Text("左键").tag(UInt8(1))
                        Text("右键").tag(UInt8(2))
                        Text("移动指针").tag(UInt8(0))
                    }.pickerStyle(.segmented)
                    HStack {
                        TextField("发送到当前输入框", text: $text)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(sendText)
                        Button("发送", action: sendText).disabled(!canSend)
                    }
                    if text.utf8.count > 1024 {
                        Text("每次最多发送 1024 字节，请把文字分段。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("回车") { model.sendKey(1) }
                        Button("退格") { model.sendKey(2) }
                        Button("Tab") { model.sendKey(3) }
                        Button("Esc") { model.sendKey(4) }
                        Button { model.scroll(3) } label: { Image(systemName: "arrow.up") }
                            .help("在指针位置向上滚动").accessibilityLabel("向上滚动")
                        Button { model.scroll(-3) } label: { Image(systemName: "arrow.down") }
                            .help("在指针位置向下滚动").accessibilityLabel("向下滚动")
                    }.buttonStyle(.bordered).controlSize(.small)
                }.disabled(model.frame == nil).padding(.horizontal).padding(.vertical, 6)
            }
        }
    }

    private var canSend: Bool { !text.isEmpty && text.utf8.count <= 1024 }
    private func sendText() {
        guard canSend else { return }
        model.sendText(text)
        text = ""
    }
}
