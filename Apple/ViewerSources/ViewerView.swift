import SwiftUI
import Network
import CoreGraphics
#if os(iOS)
import UIKit
#else
import AppKit
#endif

private enum ViewerPointerAction: UInt8 {
    case move = 0, leftClick, rightClick, leftDown, leftUp, rightDown, rightUp, leftDoubleClick
}

struct ViewerPointerGeometry {
    static func fittedSize(image: CGSize, viewport: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0, viewport.width > 0, viewport.height > 0 else { return .zero }
        let scale = min(viewport.width / image.width, viewport.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }

    static func absolute(_ point: CGPoint, in size: CGSize) -> (x: UInt16, y: UInt16)? {
        guard size.width > 0, size.height > 0 else { return nil }
        return encode(CGPoint(x: point.x / size.width, y: point.y / size.height))
    }

    static func relative(_ delta: CGPoint, to position: (x: UInt16, y: UInt16), in size: CGSize) -> (x: UInt16, y: UInt16)? {
        guard size.width > 0, size.height > 0 else { return nil }
        let range = CGFloat(UInt16.max)
        return encode(CGPoint(x: CGFloat(position.x) / range + delta.x / size.width,
                              y: CGFloat(position.y) / range + delta.y / size.height))
    }

    private static func encode(_ point: CGPoint) -> (x: UInt16, y: UInt16)? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        func normalize(_ value: CGFloat) -> UInt16 {
            UInt16((max(0, min(1, value)) * CGFloat(UInt16.max)).rounded())
        }
        return (normalize(point.x), normalize(point.y))
    }
}

private final class ViewerModel: ObservableObject {
    @Published var host = ""
    @Published var port = "47831"
    @Published var fingerprint = ""
    @Published var secret = ""
    @Published private(set) var message = ""
    @Published private(set) var connecting = false
    @Published private(set) var viewing = false
    @Published private(set) var canControl = false
    @Published private(set) var pointerEdges = false
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
            case .approved(let control, let pointerEdges):
                self.connecting = false
                self.viewing = true
                self.canControl = control
                self.pointerEdges = pointerEdges
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
        pointerEdges = false
        message = reason
    }

    deinit { session?.stop() }

    func pointer(_ action: ViewerPointerAction, at point: CGPoint? = nil, in size: CGSize = .zero) {
        guard canControl, frame != nil else { return }
        if let point = point {
            guard let position = ViewerPointerGeometry.absolute(point, in: size) else { return }
            pointerPosition = position
        }
        session?.pointer(x: pointerPosition.x, y: pointerPosition.y, action: action.rawValue)
    }

    func movePointer(by delta: CGPoint, in size: CGSize) {
        guard canControl, frame != nil,
              let position = ViewerPointerGeometry.relative(delta, to: pointerPosition, in: size) else { return }
        pointerPosition = position
        pointer(.move)
    }

    func scroll(_ ticks: Int16, at point: CGPoint? = nil, in size: CGSize = .zero) {
        guard canControl, frame != nil else { return }
        if let point = point {
            guard let position = ViewerPointerGeometry.absolute(point, in: size) else { return }
            pointerPosition = position
        }
        session?.scroll(x: pointerPosition.x, y: pointerPosition.y, ticks: ticks)
    }

    func releasePointerButtons() { session?.releasePointerButtons() }

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
    #if os(iOS)
    @State private var inputMode: ViewerTouchMode = .trackpad
    #endif
    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            if model.viewing { desktop } else { connectionForm }
        }
        #if os(iOS)
        .onChange(of: scenePhase) { phase in
            if phase != .active { model.releasePointerButtons() }
            if phase == .background && (model.viewing || model.connecting) { model.disconnect() }
        }
        #endif
        .onChange(of: model.viewing) { viewing in
            if !viewing { text = "" }
        }
        .onDisappear { model.releasePointerButtons() }
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
                    if model.canControl && !model.pointerEdges {
                        Text("升级主机可使用拖动和双击").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("断开", role: .destructive) { model.disconnect() }.buttonStyle(.bordered)
            }
            .padding(.horizontal).padding(.vertical, 6)

            GeometryReader { geometry in
                ZStack {
                    Color.black
                    if let image = model.frame, geometry.size.width > 0, geometry.size.height > 0 {
                        let size = ViewerPointerGeometry.fittedSize(
                            image: CGSize(width: image.width, height: image.height), viewport: geometry.size)
                        Image(decorative: image, scale: 1, orientation: .up)
                            .resizable()
                            .frame(width: size.width, height: size.height)
                            .accessibilityLabel("远程桌面画面")
                        if model.canControl {
                            #if os(iOS)
                            let surface = inputMode == .trackpad ? geometry.size : size
                            ViewerTouchSurface(model: model, mode: inputMode, imageSize: size,
                                               pointerEdges: model.pointerEdges, active: scenePhase == .active)
                                .frame(width: surface.width, height: surface.height)
                            #else
                            ViewerMouseSurface(model: model, pointerEdges: model.pointerEdges)
                                .frame(width: size.width, height: size.height)
                            #endif
                        }
                    } else {
                        ProgressView(model.message).tint(.white).foregroundStyle(.white)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }

            if model.canControl {
                VStack(spacing: 7) {
                    #if os(iOS)
                    Picker("触屏模式", selection: $inputMode) {
                        Text("触控板").tag(ViewerTouchMode.trackpad)
                        Text("直接触控").tag(ViewerTouchMode.direct)
                    }.pickerStyle(.segmented)
                    Text(model.pointerEdges ? "按住再移动可拖动 · 双指轻点右击 · 双指滑动滚动" : "双指轻点右击 · 双指滑动滚动")
                        .font(.caption).foregroundStyle(.secondary)
                    #endif
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

private struct ViewerScrollTicks {
    private var remainder: CGFloat = 0

    mutating func consume(_ delta: CGFloat, unitsPerTick: CGFloat) -> Int16? {
        guard delta.isFinite else { return nil }
        remainder += delta
        let ticks = (remainder / unitsPerTick).rounded(.towardZero)
        guard ticks != 0 else { return nil }
        remainder.formTruncatingRemainder(dividingBy: unitsPerTick)
        return Int16(max(-10, min(10, ticks)))
    }
}

#if os(iOS)
private enum ViewerTouchMode {
    case trackpad, direct
}

private struct ViewerTouchSurface: UIViewRepresentable {
    let model: ViewerModel
    let mode: ViewerTouchMode
    let imageSize: CGSize
    let pointerEdges: Bool
    let active: Bool

    func makeUIView(context: Context) -> ViewerTouchView { ViewerTouchView() }

    func updateUIView(_ view: ViewerTouchView, context: Context) {
        view.configure(model: model, mode: mode, imageSize: imageSize, pointerEdges: pointerEdges, active: active)
    }

    static func dismantleUIView(_ view: ViewerTouchView, coordinator: ()) { view.cancelInteractions() }
}

private final class ViewerTouchView: UIView {
    private weak var model: ViewerModel?
    private var mode: ViewerTouchMode = .trackpad
    private var imageSize: CGSize = .zero
    private var layoutSize: CGSize = .zero
    private var pointerEdges = false
    private var active = false
    private var dragPoint: CGPoint?
    private var wheel = ViewerScrollTicks()

    private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
    private lazy var legacyTap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
    private lazy var doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
    private lazy var rightTap = UITapGestureRecognizer(target: self, action: #selector(rightTapped(_:)))
    private lazy var movePan = UIPanGestureRecognizer(target: self, action: #selector(moved(_:)))
    private lazy var scrollPan = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
    private lazy var dragPress = UILongPressGestureRecognizer(target: self, action: #selector(dragged(_:)))
    private var inputRecognizers: [UIGestureRecognizer] { [tap, legacyTap, doubleTap, rightTap, movePan, scrollPan, dragPress] }

    init() {
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        doubleTap.numberOfTapsRequired = 2
        tap.require(toFail: doubleTap)
        rightTap.numberOfTouchesRequired = 2
        movePan.maximumNumberOfTouches = 1
        scrollPan.minimumNumberOfTouches = 2
        scrollPan.maximumNumberOfTouches = 2
        dragPress.numberOfTouchesRequired = 1
        dragPress.minimumPressDuration = 0.3
        dragPress.allowableMovement = 12
        for recognizer in inputRecognizers {
            addGestureRecognizer(recognizer)
        }
        updateRecognizers()
    }

    required init?(coder: NSCoder) { nil }

    func configure(model: ViewerModel, mode: ViewerTouchMode, imageSize: CGSize, pointerEdges: Bool, active: Bool) {
        guard self.model !== model || self.mode != mode || self.imageSize != imageSize
                || self.pointerEdges != pointerEdges || self.active != active else { return }
        cancelInteractions()
        self.model = model
        self.mode = mode
        self.imageSize = imageSize
        self.pointerEdges = pointerEdges
        self.active = active
        updateRecognizers()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard layoutSize != bounds.size else { return }
        layoutSize = bounds.size
        cancelInteractions()
        updateRecognizers()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        cancelInteractions()
        updateRecognizers()
    }

    func cancelInteractions() {
        model?.releasePointerButtons()
        dragPoint = nil
        wheel = ViewerScrollTicks()
        inputRecognizers.forEach { $0.isEnabled = false }
    }

    private func updateRecognizers() {
        let active = active && window != nil
        tap.isEnabled = active && pointerEdges
        legacyTap.isEnabled = active && !pointerEdges
        doubleTap.isEnabled = active && pointerEdges
        rightTap.isEnabled = active
        movePan.isEnabled = active && mode == .trackpad
        scrollPan.isEnabled = active
        dragPress.isEnabled = active && pointerEdges
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        click(.leftClick, at: gesture.location(in: self))
    }

    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer) {
        click(.leftDoubleClick, at: gesture.location(in: self))
    }

    @objc private func rightTapped(_ gesture: UITapGestureRecognizer) {
        click(.rightClick, at: gesture.location(in: self))
    }

    private func click(_ action: ViewerPointerAction, at point: CGPoint) {
        guard active, bounds.contains(point) else { return }
        pointer(action, at: point)
    }

    @objc private func moved(_ gesture: UIPanGestureRecognizer) {
        guard active, gesture.state == .began || gesture.state == .changed || gesture.state == .ended else { return }
        model?.movePointer(by: gesture.translation(in: self), in: imageSize)
        gesture.setTranslation(.zero, in: self)
    }

    @objc private func scrolled(_ gesture: UIPanGestureRecognizer) {
        guard active else { return }
        if gesture.state == .began { wheel = ViewerScrollTicks() }
        guard gesture.state == .began || gesture.state == .changed else { return }
        let point = gesture.location(in: self)
        let delta = gesture.translation(in: self).y
        gesture.setTranslation(.zero, in: self)
        if let ticks = wheel.consume(delta, unitsPerTick: 18) {
            model?.scroll(ticks, at: mode == .direct ? point : nil, in: bounds.size)
        }
    }

    @objc private func dragged(_ gesture: UILongPressGestureRecognizer) {
        guard active else { return }
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            guard gesture.numberOfTouches == 1, bounds.contains(point) else { return }
            dragPoint = point
            pointer(.leftDown, at: point)
        case .changed, .ended:
            guard let previous = dragPoint else { return }
            if gesture.numberOfTouches > 1 {
                dragPoint = nil
                model?.releasePointerButtons()
                return
            }
            if previous != point {
                if mode == .trackpad {
                    model?.movePointer(by: CGPoint(x: point.x - previous.x, y: point.y - previous.y), in: imageSize)
                } else {
                    pointer(.move, at: point)
                }
            }
            if gesture.state == .ended {
                dragPoint = nil
                pointer(.leftUp, at: point)
            } else {
                dragPoint = point
            }
        case .cancelled, .failed:
            if dragPoint != nil { model?.releasePointerButtons() }
            dragPoint = nil
        default: break
        }
    }

    private func pointer(_ action: ViewerPointerAction, at point: CGPoint) {
        model?.pointer(action, at: mode == .direct ? point : nil, in: bounds.size)
    }
}
#else
private struct ViewerMouseSurface: NSViewRepresentable {
    let model: ViewerModel
    let pointerEdges: Bool

    func makeNSView(context: Context) -> ViewerMouseView { ViewerMouseView(frame: .zero) }

    func updateNSView(_ view: ViewerMouseView, context: Context) {
        view.model = model
        view.pointerEdges = pointerEdges
    }

    static func dismantleNSView(_ view: ViewerMouseView, coordinator: ()) { view.cancelInteractions() }
}

private final class ViewerMouseView: NSView {
    weak var model: ViewerModel?
    var pointerEdges = false
    private var hover: NSTrackingArea?
    private var leftHeld = false
    private var rightHeld = false
    private var wheel = ViewerScrollTicks()

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hover = hover { removeTrackingArea(hover) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hover = area
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window = window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
            cancelInteractions()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window = window else { return }
        window.acceptsMouseMovedEvents = true
        NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey(_:)),
                                               name: NSWindow.didResignKeyNotification, object: window)
    }

    @objc private func windowResignedKey(_ notification: Notification) { cancelInteractions() }

    func cancelInteractions() {
        leftHeld = false
        rightHeld = false
        wheel = ViewerScrollTicks()
        model?.releasePointerButtons()
    }

    override func mouseMoved(with event: NSEvent) {
        let point = location(of: event)
        if window?.isKeyWindow == true, bounds.contains(point) { pointer(.move, at: point) }
    }

    override func mouseDown(with event: NSEvent) {
        let point = location(of: event)
        guard window?.isKeyWindow == true, bounds.contains(point) else { return }
        leftHeld = pointerEdges
        pointer(pointerEdges ? .leftDown : .leftClick, at: point)
    }

    override func mouseUp(with event: NSEvent) {
        guard leftHeld else { return }
        leftHeld = false
        pointer(.leftUp, at: location(of: event))
    }

    override func mouseDragged(with event: NSEvent) {
        if leftHeld { pointer(.move, at: location(of: event)) }
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = location(of: event)
        guard window?.isKeyWindow == true, bounds.contains(point) else { return }
        rightHeld = pointerEdges
        pointer(pointerEdges ? .rightDown : .rightClick, at: point)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard rightHeld else { return }
        rightHeld = false
        pointer(.rightUp, at: location(of: event))
    }

    override func rightMouseDragged(with event: NSEvent) {
        if rightHeld { pointer(.move, at: location(of: event)) }
    }

    override func scrollWheel(with event: NSEvent) {
        let point = location(of: event)
        guard window?.isKeyWindow == true, bounds.contains(point) else { return }
        if event.phase.contains(.began) { wheel = ViewerScrollTicks() }
        if let ticks = wheel.consume(event.scrollingDeltaY, unitsPerTick: event.hasPreciseScrollingDeltas ? 16 : 1) {
            model?.scroll(ticks, at: point, in: bounds.size)
        }
    }

    private func location(of event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    private func pointer(_ action: ViewerPointerAction, at point: CGPoint) {
        model?.pointer(action, at: point, in: bounds.size)
    }
}
#endif
