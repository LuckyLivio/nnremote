# Livio Remote 0.1.0

用 iPhone、Windows 或 Mac 连接你有权操作的电脑。Windows 和 Mac 都可以共享主屏幕。iPhone 是控制端。Apple 客户端使用 SwiftUI，Windows 客户端使用 WinForms 和 Win32。三个客户端使用同一套本项目实现的桌面传输协议，调用系统的 TLS、JPEG 编解码和输入接口。没有在线账号、遥测、广告或会话录像。

## 先连一次自己的电脑

1. 让两台设备连到同一个可互访的 Wi-Fi，将共享电脑保持在开机、登录并唤醒的状态。好友可用自己的电脑生成邀请。
2. 在 Windows 版打开「共享这台电脑」→「开始共享」。Mac 版选择「共享这台 Mac」→「开启共享」。macOS 会请求屏幕录制权限，允许操作键鼠另需「辅助功能」权限。在 Mac 上保持共享标签页和窗口打开。
3. 在主机选择另一台设备可达的地址，点击「复制连接邀请（含密钥）」，私下传到控制端。常见的局域网 IPv4 形如 192.168.x.x，默认端口为 47831。电脑可能同时拥有 Wi-Fi、虚拟网卡和 Tailscale 地址，按当前连接路径选一个。
4. 控制端选择「连接电脑」并粘贴邀请，确认来源后请求连接。主机选择「仅查看」或「允许控制」。看到桌面后，试着滚动文档、在记事本输入一行中文，然后从主机停止共享，确认画面随即消失。
5. 如果你打算出门后连自己家里的电脑，在出门前选择「单次预授权」，选定权限，再将新邀请复制到自己的设备。持有邀请的第一台通过验证的设备可在 8 小时内接入一次，断开后需要本机再次授权。Windows 的预授权会话也会在预设的 8 小时截止时间结束。主机需要保持唤醒。普通共享期间，每次连接都由本机确认，停止后旧邀请失效。

不要把邀请贴到公共群聊。邀请里包含完整证书指纹和配对密钥，尤其是单次预授权，先使用的持有人可以取得预设权限。中继连接在共享电脑上显示的来源可能是本机回环地址，无法据此辨认远端的人。

## 在哪种网络上使用

| 场景 | 邀请中填写的地址 | 条件 |
|---|---|---|
| 同一个局域网 | 主机的局域网 IPv4、IPv6 或可解析的主机名，端口 47831 | 两台设备能互访，主机允许此 App 收到本地连接 |
| 已有 Tailscale | 共享电脑在 Tailscale 里的地址，端口 47831 | 双方能通过已有的私有网络访问这台电脑。App 不需要 Tailscale 的账号、命令行或 SDK |
| 直接可达的网络 | 主机可达的 IP 或域名，端口 47831 | 路由和防火墙允许访问。单有公网 IPv6 地址并不能保证可达 |
| 两边都在内网，且没有现成私有网络 | 自己的中继域名，默认观看端口 47833 | 共享电脑主动连接中继，观看端连接同一个中继。跨 IPv4/IPv6 需要中继两侧均可达 |

初版从邀请确定连接路径。它尚未实现设备发现、自动 NAT 打洞和直连失败后无感切换中继。选局域网或已有的 Tailscale 路径时，无需为本项目在家庭路由器上设置端口转发。学校或酒店 Wi-Fi 的客户端隔离可能阻止同网连接。

## 运行与构建

**Windows 11 x64**　体验包里解压运行 LivioRemote.exe，包含 .NET 桌面运行时。程序以当前用户身份启动。首次在受信任的家庭网络上作为主机时，Windows 可能询问防火墙权限。普通用户进程的输入受 Windows 权限边界约束，UAC 安全桌面和部分以管理员身份运行的窗口无法远程操作。

从源码运行时先安装 .NET 10 SDK，然后在本目录打开 PowerShell。

```powershell
dotnet run --project .\Windows\LivioRemote.csproj
```

重新制作含运行时的 x64 包使用以下命令。输出位于 out/win-x64。

```powershell
dotnet publish .\Windows\LivioRemote.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:EnableCompressionInSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:DebugType=None -p:DebugSymbols=false -o .\out\win-x64
```

**macOS 与 iPhone**　在装有 Xcode 26 或更新版本的 Mac 上双击 Apple/LivioRemote.xcodeproj。选择 LivioRemote-macOS 和 My Mac，按 ⌘R。项目的 Mac 最低部署版本为 macOS 14，iPhone 为 iOS 16，真机调试时使用支持该设备系统版本的 Xcode。iPhone 安装时，在 LivioRemote-iOS 的 Signing & Capabilities 中指定自己的 Team 和唯一 Bundle Identifier，再选 iPhone 运行。局域网连接时允许本地网络访问。朋友使用 iOS 版，后续可用签名构建和 TestFlight 内测；源码包没有已签名的 IPA。Mac 项目采用非沙盒配置以便在用户明确授予辅助功能权限后发送输入。

也可以在 Mac 上先验证两个 target，无需在模拟器里签名。命令仅构建。

```bash
cd Apple
xcodebuild -project LivioRemote.xcodeproj -scheme LivioRemote-macOS -configuration Debug -destination 'platform=macOS' build
xcodebuild -project LivioRemote.xcodeproj -scheme LivioRemote-iOS -configuration Debug -destination 'generic/platform=iOS Simulator' build
```

## 自己架设中继

如果只是本人现有的 Tailscale 设备互连，可以跳过本节。中继负责转发控制端与桌面主机之间的 TLS 字节。观看端核对邀请里桌面主机的证书，配对密钥在此后才发送。中继仍可观察连接时间、IP 和流量大小。真实的互联网延迟、线路稳定性和服务器带宽影响体验。运行服务器、传输流量可能产生成本。

1. 准备一台共享电脑和朋友都可访问的服务器，安装 Python 3.10+ 和 OpenSSL。把 Link/relay.py 复制过去。用普通账号执行以下两行，在服务器防火墙中允许业务所需 TCP 47832 和 47833。共享电脑只需向外连接。
   ```bash
   python3 relay.py init livio-relay
   python3 relay.py serve livio-relay
   ```
2. 只把 livio-relay/link.json 通过可信渠道交给共享电脑的主人。证书私钥 relay-key.pem 留在服务器。该配置使用单独的中继密钥，与桌面邀请分开。服务器证书默认有效期一年；更换中继证书或轮换密钥时，在新目录重新 init，再私下更新共享电脑的 link.json。
3. 共享电脑按平时开启共享，同时保持以下命令运行。将 relay.example.net 换成自己服务器的真实地址。Windows 可把 python3 换成 py -3。
   ```bash
   python3 Link/relay.py link relay.example.net link.json
   ```
4. 在共享电脑的邀请地址中填同一中继域名，邀请端口填 47833，重新复制邀请。朋友粘贴后即可请求连接，对方只运行原生控制端。停止共享可立即断开桌面。结束 link 或 serve 也会关闭中继连接。

每个中继实例对应一台正在共享的主机，每次接入一个观看端。多位朋友可以依次使用同一台主机。如果多台主机要同时共享，可每台使用单独配置和一对端口。serve 支持 --bridge-port 与 --viewer-port，link 的 --bridge-port 要与服务器一致；邀请填写对应观看端口。客户端间没有共享设备目录。

## 当前功能与 UU 对照

| 体验 | 0.1.0 实现 | 后续验收 |
|---|---|---|
| 桌面查看、键鼠控制 | 主屏幕、左/右键、滚动、单行 Unicode 文字和四个常用按键。等比显示并换算点击坐标 | 拖选、组合键、完整物理键盘、iPhone 触控板与缩放 |
| 自己连回家、帮朋友 | 含指纹与密钥的邀请、逐次批准、仅观看、停止共享、一次预授权 | 可单独撤销的长期可信设备、设备收藏和断线恢复 |
| 内外网 | IPv4、IPv6、DNS、已有私网、可选双栈自托管中继 | 自动探测与择路、NAT 穿透、多主机共享同一服务 |
| 办公资料与多屏 | 现有单屏会话可以操作桌面上的应用 | 用户授权的剪贴板、文件收发与断点续传、多屏切换、隐私屏、远程唤醒 |
| 游戏与音视频 | 使用独立 JPEG 帧，尺寸上限 1920×1080。Windows 帧间等待 125 ms，Mac 等待 100 ms，采集、编码和传输还会耗时 | 系统硬件 H.264/HEVC、声音、麦克风、手柄、按键映射、自适应码率。先实测 1080p60，再验证 4K 与高刷新率 |
| 其他 UU 体验 | 此版聚焦桌面与协助 | 单独评估虚拟屏/无屏主机、无线副屏、小窗、真彩、游戏宏、终端/CLI、受控服务映射、设备锁；涉及新增权限的功能需独立开关 |

网易公开功能说明可作为逐项核验的基准。当前可核实的差异包括高刷串流、手柄、多屏、文件传输和隐私屏。[网易 UU 远程产品说明](https://apps.apple.com/cn/app/id1642306791)

## 验证范围

源码包含网络测试与双平台构建入口。Python 套件使用本机回环上的真实 TLS 和中继，使用参考桌面端收发少量 JPEG、控制消息和断开消息。它覆盖错误指纹、错误密钥、重复连接、转发密文、断线重连与可用时的 IPv6。Windows 发布构建可在有 .NET 10 SDK 的环境复现。已完成的检查不包含 Win32 真机采集、Apple 真机编译、实际运营商链路或游戏帧率测试。

```bash
python3 -m unittest discover -s Tests -v
dotnet run --project Tests/WindowsHostTransport/WindowsHostTransport.csproj
```

请依次运行两组测试。它们使用本机 TCP 47831，先关闭本机正在运行的桌面共享。Python 的 9 项测试已在 Linux 通过，包括 IPv6 分支。第二组在 .NET 10 下直接编译共享端产品代码，使用固定测试画面和输入记录器，核验 TLS、授权前无画面、仅查看权限、控制指令和一次授权后关闭监听。

首次实机验收推荐按「iPhone → Windows」「Mac → Windows」「Windows → Mac」各测一次。分别检查仅查看、允许控制、滚动与中文输入，以及主机停止后控制端立即退出。随后让 iPhone 关闭 Wi-Fi 改用蜂窝网络，再测 Tailscale 或自建中继路线。应用只在操作者主动复制或粘贴邀请时访问剪贴板。
