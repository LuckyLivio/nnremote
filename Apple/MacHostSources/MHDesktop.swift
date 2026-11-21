#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// A fixed display and scale for the lifetime of one approval. Display changes require reconnecting.
struct MHDesktop {
    let id: CGDirectDisplayID
    let bounds: CGRect
    private let filter: SCContentFilter
    private let config: SCStreamConfiguration
    private let pointer = MHRemotePointer()

    private var displayMatches: Bool { id == CGMainDisplayID() && CGDisplayBounds(id) == bounds }

    static func open() async throws -> MHDesktop {
        guard CGPreflightScreenCaptureAccess() else { throw MHError.detail("请在系统设置中允许屏幕录制，然后重新打开 App。") }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let id = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == id }) else {
            throw MHError.detail("主显示器不可用。")
        }
        // Never send the window containing the invitation or local approval controls.
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        guard !ownApps.isEmpty else { throw MHError.detail("无法排除主机授权窗口，请显示 App 窗口后重试。") }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let config = SCStreamConfiguration()
        let scale = min(1.0, 1920 / Double(max(1, display.width)), 1080 / Double(max(1, display.height)))
        config.width = max(1, Int(Double(display.width) * scale))
        config.height = max(1, Int(Double(display.height) * scale))
        config.showsCursor = true
        return MHDesktop(id: id, bounds: CGDisplayBounds(id), filter: filter, config: config)
    }

    func frame() async throws -> Data {
        guard displayMatches, CGPreflightScreenCaptureAccess() else {
            throw MHError.detail("显示器或屏幕录制权限已变更，请重新连接。")
        }
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let result = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(result as CFMutableData,
                UTType.jpeg.identifier as CFString, 1, nil) else { throw MHError.detail("无法创建画面。") }
        CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.65] as CFDictionary)
        guard CGImageDestinationFinalize(output), result.length <= 8 * 1024 * 1024 else {
            throw MHError.detail("画面编码失败。")
        }
        return result as Data
    }

    func apply(type: UInt8, payload: Data, pointerEdges: Bool) throws {
        guard AXIsProcessTrusted(), displayMatches else {
            throw MHError.detail("控制权限或显示器已变更。")
        }
        func location(_ bytes: [UInt8]) -> CGPoint {
            let x = Int(bytes[0]) * 256 + Int(bytes[1])
            let y = Int(bytes[2]) * 256 + Int(bytes[3])
            return CGPoint(x: bounds.minX + CGFloat(x) / 65535 * max(0, bounds.width - 1),
                           y: bounds.minY + CGFloat(y) / 65535 * max(0, bounds.height - 1))
        }
        switch type {
        case 32:
            let b = Array(payload)
            guard b.count == 5, let action = MHRemotePointer.Action(rawValue: b[4]),
                  pointerEdges || b[4] <= MHRemotePointer.Action.rightClick.rawValue else {
                throw MHError.detail("无效的指针指令。")
            }
            pointer.apply(action, at: location(b))
        case 33:
            guard let text = String(data: payload, encoding: .utf8), !text.isEmpty else {
                throw MHError.detail("无效的输入文本。")
            }
            // Send a Unicode scalar per event so supplementary characters stay together.
            for scalar in text.unicodeScalars {
                let units = Array(String(scalar).utf16)
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                    units.withUnsafeBufferPointer {
                        event?.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
                    }
                    event?.post(tap: .cghidEventTap)
                }
            }
        case 34:
            let codes: [UInt8: CGKeyCode] = [1: 36, 2: 51, 3: 48, 4: 53]
            guard payload.count == 1, let raw = payload.first, let code = codes[raw] else {
                throw MHError.detail("无效的按键。")
            }
            for down in [true, false] {
                CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)?.post(tap: .cghidEventTap)
            }
        case 35:
            let b = Array(payload)
            guard b.count == 6 else { throw MHError.detail("无效的滚动指令。") }
            let ticks = Int32(Int16(bitPattern: (UInt16(b[4]) << 8) | UInt16(b[5])))
            guard (-10...10).contains(ticks) else { throw MHError.detail("滚动幅度超出限制。") }
            let point = location(b)
            pointer.apply(.move, at: point)
            let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                 wheel1: ticks, wheel2: 0, wheel3: 0)
            scroll?.location = point
            scroll?.post(tap: .cghidEventTap)
        default: throw MHError.detail("无法识别的控制指令。")
        }
    }

    func releasePointerButtons() {
        // If display geometry changed, release at the system cursor when it is available.
        pointer.releaseAll(at: displayMatches ? nil : CGEvent(source: nil)?.location)
    }
}

/// Input state belongs to one approved session and runs serially on the host's main actor.
final class MHRemotePointer {
    enum Action: UInt8 {
        case move = 0, leftClick, rightClick, leftDown, leftUp, rightDown, rightUp, leftDoubleClick
    }

    private enum Button: CaseIterable {
        case left, right

        var eventButton: CGMouseButton { self == .left ? .left : .right }
        var down: CGEventType { self == .left ? .leftMouseDown : .rightMouseDown }
        var up: CGEventType { self == .left ? .leftMouseUp : .rightMouseUp }
        var drag: CGEventType { self == .left ? .leftMouseDragged : .rightMouseDragged }
    }

    private struct Press {
        let start: CGPoint
        let time: TimeInterval
        let count: Int64
        var dragged = false
    }

    private struct Click {
        let button: Button
        let press: Press
    }

    typealias Emit = (CGEventType, CGPoint, CGMouseButton, Int64) -> Bool

    private let emit: Emit
    private var held: [Button: Press] = [:]
    private var lastClick: Click?
    private var lastLocation: CGPoint?

    init(emit: @escaping Emit = MHRemotePointer.post) {
        self.emit = emit
    }

    func apply(_ action: Action, at point: CGPoint) {
        switch action {
        case .move: move(to: point)
        case .leftClick: click(.left, at: point)
        case .rightClick: click(.right, at: point)
        case .leftDown: _ = down(.left, at: point)
        case .leftUp: up(.left, at: point)
        case .rightDown: _ = down(.right, at: point)
        case .rightUp: up(.right, at: point)
        case .leftDoubleClick:
            click(.left, at: point, count: 1)
            click(.left, at: point, count: 2)
        }
    }

    func releaseAll(at fallback: CGPoint? = nil) {
        guard let point = fallback ?? lastLocation else { return }
        for button in Button.allCases {
            if let press = held[button] {
                _ = emit(button.up, point, button.eventButton, press.count)
            }
        }
        held.removeAll()
        lastClick = nil
        lastLocation = nil
    }

    private func move(to point: CGPoint) {
        for button in Button.allCases {
            if let press = held[button], !near(point, press.start) {
                held[button]?.dragged = true
            }
        }
        if let button = Button.allCases.first(where: { held[$0] != nil }), let press = held[button] {
            _ = emit(button.drag, point, button.eventButton, press.count)
        } else {
            _ = emit(.mouseMoved, point, .left, 0)
        }
        lastLocation = point
    }

    private func click(_ button: Button, at point: CGPoint, count: Int64? = nil) {
        if down(button, at: point, count: count) {
            up(button, at: point)
        }
    }

    private func down(_ button: Button, at point: CGPoint, count: Int64? = nil) -> Bool {
        guard held[button] == nil else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        let clickCount = count ?? inferredCount(button, at: point, now: now)
        guard emit(button.down, point, button.eventButton, clickCount) else { return false }
        held[button] = Press(start: point, time: now, count: clickCount)
        lastClick = nil
        lastLocation = point
        return true
    }

    private func up(_ button: Button, at point: CGPoint) {
        guard held[button] != nil else { return }
        if point != lastLocation { move(to: point) }
        guard let press = held[button], emit(button.up, point, button.eventButton, press.count) else { return }
        held.removeValue(forKey: button)
        if !press.dragged, ProcessInfo.processInfo.systemUptime - press.time <= NSEvent.doubleClickInterval {
            lastClick = Click(button: button, press: press)
        }
    }

    private func inferredCount(_ button: Button, at point: CGPoint, now: TimeInterval) -> Int64 {
        guard let click = lastClick, click.button == button,
              now - click.press.time <= NSEvent.doubleClickInterval, near(point, click.press.start) else { return 1 }
        return click.press.count + 1
    }

    private func near(_ first: CGPoint, _ second: CGPoint) -> Bool {
        abs(first.x - second.x) <= 4 && abs(first.y - second.y) <= 4
    }

    private static func post(_ type: CGEventType, _ point: CGPoint, _ button: CGMouseButton, _ count: Int64) -> Bool {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
        else { return false }
        if count > 0 { event.setIntegerValueField(.mouseEventClickState, value: count) }
        event.post(tap: .cghidEventTap)
        return true
    }
}

func MHAddresses() -> [String] {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return [] }
    defer { freeifaddrs(head) }
    var values: [String] = []
    var next: UnsafeMutablePointer<ifaddrs>? = first
    while let node = next {
        let item = node.pointee
        next = item.ifa_next
        guard (item.ifa_flags & UInt32(IFF_UP)) != 0,
              (item.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
              let address = item.ifa_addr else { continue }
        let family = Int32(address.pointee.sa_family)
        guard family == AF_INET || family == AF_INET6 else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(address, socklen_t(address.pointee.sa_len), &host,
                       socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
            let text = String(cString: host)
            // Link-local IPv6 needs an interface index on the viewer's network interface.
            if !text.lowercased().hasPrefix("fe80:"), !values.contains(text) { values.append(text) }
        }
    }
    return values.sorted()
}
#endif
