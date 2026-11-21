import Foundation
import Network

@main
struct PointerClient {
    static func main() {
        let args = CommandLine.arguments
        if args[1] == "geometry" {
            checkGeometry()
            return
        }
        let port = NWEndpoint.Port(rawValue: UInt16(args[1])!)!
        let pin = Data(stride(from: 0, to: args[2].count, by: 2).map { offset in
            let start = args[2].index(args[2].startIndex, offsetBy: offset)
            return UInt8(args[2][start..<args[2].index(start, offsetBy: 2)], radix: 16)!
        })
        let endpoint = ViewerEndpoint(host: "127.0.0.1", port: port, fingerprint: pin, secret: args[3])
        var transport: ViewerTransport!
        var stopping = false
        transport = ViewerTransport(endpoint: endpoint) { event in
            switch event {
            case .approved(let control, let pointerEdges):
                print("approved \(control) \(pointerEdges)")
                transport.pointer(x: 200, y: 300, action: 3)
                for x in 201...1_200 {
                    transport.pointer(x: UInt16(x), y: 301, action: 0)
                }
                transport.pointer(x: 1_201, y: 302, action: 4)
                transport.pointer(x: 1_202, y: 303, action: 1)
                transport.scroll(x: 1_203, y: 304, ticks: -2)
                transport.pointer(x: 1_204, y: 305, action: 5)
                stopping = true
                transport.stop()
            case .ended(let message):
                if stopping && message == "已断开。" { exit(0) }
                FileHandle.standardError.write(Data(message.utf8))
                exit(1)
            default:
                break
            }
        }
        transport.start()
        dispatchMain()
    }

    private static func checkGeometry() {
        let image = CGSize(width: 1920, height: 1080)
        let portrait = ViewerPointerGeometry.fittedSize(image: image, viewport: CGSize(width: 400, height: 800))
        let landscape = ViewerPointerGeometry.fittedSize(image: image, viewport: CGSize(width: 800, height: 450))
        precondition(portrait == CGSize(width: 400, height: 225))
        precondition(landscape == CGSize(width: 800, height: 450))
        let portraitPoint = ViewerPointerGeometry.absolute(CGPoint(x: 200, y: 112.5), in: portrait)
        let landscapePoint = ViewerPointerGeometry.absolute(CGPoint(x: 400, y: 225), in: landscape)
        precondition(portraitPoint?.x == 32768 && portraitPoint?.y == 32768)
        precondition(portraitPoint?.x == landscapePoint?.x && portraitPoint?.y == landscapePoint?.y)

        let outside = ViewerPointerGeometry.absolute(CGPoint(x: -70, y: 350), in: portrait)
        precondition(outside?.x == 0 && outside?.y == UInt16.max)
        let relative = ViewerPointerGeometry.relative(CGPoint(x: 800, y: -800), to: (1200, 1200), in: portrait)
        precondition(relative?.x == UInt16.max && relative?.y == 0)
        precondition(ViewerPointerGeometry.absolute(.zero, in: .zero) == nil)
    }
}
