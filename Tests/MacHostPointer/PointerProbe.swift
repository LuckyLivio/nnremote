import CoreGraphics
import Foundation

@main
struct PointerProbe {
    struct Event: Equatable {
        let type: CGEventType
        let at: CGPoint
        let button: CGMouseButton
        let count: Int64
    }
    static func main() {
        let origin = CGPoint(x: 10, y: 20)
        let away = CGPoint(x: 110, y: 210)
        let fallback = CGPoint(x: 300, y: 350)
        var events: [Event] = []
        let pointer = MHRemotePointer { type, at, button, count in
            events.append(Event(type: type, at: at, button: button, count: count))
            return true
        }

        pointer.apply(.move, at: origin)
        pointer.apply(.leftDown, at: origin)
        pointer.apply(.leftDown, at: away)   // Duplicate down is ignored.
        pointer.apply(.move, at: away)
        pointer.apply(.leftUp, at: origin)   // A final motion is emitted before the up.
        pointer.apply(.leftUp, at: away)     // Unmatched up is ignored.
        pointer.releaseAll()
        precondition(events.map { $0.type } == [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseDragged, .leftMouseUp])
        precondition(events.last?.at == origin)
        events.removeAll()

        pointer.apply(.rightDown, at: origin)
        pointer.apply(.move, at: away)
        pointer.releaseAll()
        pointer.releaseAll()
        precondition(events.map { $0.type } == [.rightMouseDown, .rightMouseDragged, .rightMouseUp])
        precondition(events.last?.at == away && events.last?.button == .right)
        events.removeAll()

        pointer.apply(.leftDown, at: origin)
        pointer.apply(.rightDown, at: origin)
        pointer.releaseAll(at: fallback)
        precondition(events.map { $0.type } == [.leftMouseDown, .rightMouseDown, .leftMouseUp, .rightMouseUp])
        precondition(events.suffix(2).allSatisfy { $0.at == fallback })
        events.removeAll()

        pointer.apply(.leftDown, at: origin)
        pointer.apply(.leftUp, at: origin)
        pointer.apply(.leftDown, at: origin)
        pointer.apply(.leftUp, at: origin)
        precondition(events.map { $0.type } == [.leftMouseDown, .leftMouseUp, .leftMouseDown, .leftMouseUp])
        precondition(events.map { $0.count } == [1, 1, 2, 2])
        events.removeAll()

        pointer.apply(.leftDoubleClick, at: away)
        pointer.releaseAll()
        precondition(events.map { $0.type } == [.leftMouseDown, .leftMouseUp, .leftMouseDown, .leftMouseUp])
        precondition(events.map { $0.count } == [1, 1, 2, 2])
        events.removeAll()

        pointer.apply(.leftDown, at: origin)
        pointer.apply(.move, at: away)
        pointer.apply(.move, at: origin)
        pointer.apply(.leftUp, at: origin)
        pointer.apply(.leftClick, at: origin)
        pointer.apply(.leftClick, at: away)
        precondition(events.filter { $0.type == .leftMouseDown }.map { $0.count } == [1, 1, 1])
        events.removeAll()

        let unavailable = MHRemotePointer { type, at, button, count in
            events.append(Event(type: type, at: at, button: button, count: count))
            return false
        }
        unavailable.apply(.leftDown, at: origin)
        unavailable.releaseAll()
        precondition(events.map { $0.type } == [.leftMouseDown])
        print("Passed macOS remote pointer dispatch, ordered edges, click counts and session release.")
    }
}
