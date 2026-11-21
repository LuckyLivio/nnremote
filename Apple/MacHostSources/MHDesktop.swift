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
        guard id == CGMainDisplayID(), CGDisplayBounds(id) == bounds, CGPreflightScreenCaptureAccess() else {
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

    func apply(type: UInt8, payload: Data) throws {
        guard AXIsProcessTrusted(), id == CGMainDisplayID(), CGDisplayBounds(id) == bounds else {
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
            guard b.count == 5, b[4] <= 2 else { throw MHError.detail("无效的指针指令。") }
            let point = location(b)
            let button = b[4] == 2 ? CGMouseButton.right : .left
            let events: [CGEventType] = b[4] == 0 ? [.mouseMoved]
                : (b[4] == 2 ? [.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp])
            for kind in events {
                CGEvent(mouseEventSource: nil, mouseType: kind, mouseCursorPosition: point,
                        mouseButton: button)?.post(tap: .cghidEventTap)
            }
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
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point,
                    mouseButton: .left)?.post(tap: .cghidEventTap)
            let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                 wheel1: ticks, wheel2: 0, wheel3: 0)
            scroll?.location = point
            scroll?.post(tap: .cghidEventTap)
        default: throw MHError.detail("无法识别的控制指令。")
        }
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
