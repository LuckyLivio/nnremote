#if os(macOS)
import AppKit
import SwiftUI

struct MacHostView: View {
    @StateObject private var host = MHHost()
    @State private var showPreapproval = false
    @State private var advertisedHost = ""
    @State private var advertisedPort = "47831"
    @State private var copied = false

    private var invitation: String? {
        let address = advertisedHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:%_")
        guard !address.isEmpty, address.utf8.count <= 253,
              address.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              let port = UInt16(advertisedPort), port > 0,
              host.pin.count == 64, host.secret.count == 32 else { return nil }
        return ["LRV1", address, String(port), host.pin, host.secret].joined(separator: "|")
    }

    private func copyInvitation() {
        guard let invitation else { return }
        let item = NSPasteboardItem()
        item.setString(invitation, forType: .string)
        item.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        item.setData(Data(), forType: .init("org.nspasteboard.TransientType"))
        let pasteboard = NSPasteboard.general
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        copied = pasteboard.writeObjects([item])
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("共享这台 Mac").font(.largeTitle.bold())
                Label(host.status, systemImage: host.listening ? "display" : "display.trianglebadge.exclamationmark")
                    .font(.headline)
                if host.listening {
                    Text("共享期间请保持此页打开。关闭窗口或离开本页会结束共享。").font(.callout).foregroundStyle(.secondary)
                    Button("停止共享", role: .destructive) { host.close() }
                    if host.pending {
                        GroupBox("本次连接允许什么？") {
                            HStack {
                                Button("仅观看") { host.decide(control: false) }.buttonStyle(.borderedProminent)
                                Button("允许控制") { host.decide(control: true) }
                                Button("拒绝", role: .destructive) { host.deny() }
                            }.padding(6)
                        }
                    } else if host.ready && !host.busy {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("主机地址 · TCP 47831").font(.headline)
                            ForEach(host.addresses, id: \.self) { address in
                                Text(verbatim: address).font(.body.monospaced()).textSelection(.enabled)
                            }
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("证书指纹（SHA-256）").font(.headline)
                            Text(verbatim: host.pin).font(.callout.monospaced()).textSelection(.enabled)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("配对口令").font(.headline)
                            Text(verbatim: host.secret).font(.body.monospaced()).textSelection(.enabled)
                            Text("请通过双方信任的渠道传递地址、指纹和口令。").foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("朋友连接时使用的地址与端口").font(.headline)
                            HStack {
                                TextField("主机名或 IP", text: $advertisedHost).textFieldStyle(.roundedBorder)
                                TextField("端口", text: $advertisedPort).frame(width: 75).textFieldStyle(.roundedBorder)
                            }
                            Button(copied ? "已复制邀请（含口令）" : "复制邀请（含口令）") { copyInvitation() }
                                .disabled(invitation == nil)
                        }
                        if let expiry = host.preapprovalExpiry {
                            Text((host.preapprovedControl ? "已预授权一次控制" : "已预授权一次观看")
                                + "，到期时间 " + expiry.formatted(date: .abbreviated, time: .shortened))
                            Button("撤销预授权并关闭共享", role: .destructive) { host.close("单次授权已撤销") }
                        } else {
                            DisclosureGroup("离开前预授权一次连接", isExpanded: $showPreapproval) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("启用后会生成新口令。持有新口令的第一台设备可在八小时内连接一次，到期或断开后共享自动关闭。")
                                    HStack {
                                        Button("预授权仅观看") { host.arm(control: false) }
                                        Button("预授权允许控制") { host.arm(control: true) }
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                            }
                        }
                    }
                } else {
                    Text("打开共享后，可从其他设备连接 Mac 的主显示器。默认每次都要在此窗口授权。")
                        .foregroundStyle(.secondary)
                    Button("开启共享") { host.start() }.buttonStyle(.borderedProminent)
                }
            }.padding(24).frame(maxWidth: 700, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: host.ready) { _, ready in
            if ready && advertisedHost.isEmpty {
                advertisedHost = host.addresses.first(where: { !$0.contains(":") })
                    ?? host.addresses.first ?? ProcessInfo.processInfo.hostName
            }
        }
        .onChange(of: invitation) { _, _ in copied = false }
        .background(MHWindowCloseObserver { host.close() }.frame(width: 0, height: 0))
        .onDisappear { host.close() }
    }
}

private struct MHWindowCloseObserver: NSViewRepresentable {
    let onClose: () -> Void
    func makeNSView(context: Context) -> MHWindowWatchView {
        let view = MHWindowWatchView(frame: .zero)
        view.onClose = onClose
        return view
    }
    func updateNSView(_ view: MHWindowWatchView, context: Context) { view.onClose = onClose }
}

private final class MHWindowWatchView: NSView {
    var onClose: (() -> Void)?
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
        if let newWindow {
            center.addObserver(self, selector: #selector(windowClosing(_:)),
                               name: NSWindow.willCloseNotification, object: newWindow)
        }
    }
    @objc private func windowClosing(_ note: Notification) { onClose?() }
}
#endif
