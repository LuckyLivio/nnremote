# nnremote

nnremote 是用于本人或明确授权设备的远程桌面应用。iPhone 可以控制电脑，macOS 和 Windows 可以控制电脑或共享主屏幕。Apple 客户端使用 SwiftUI，Windows 客户端使用 WinForms 和 Win32。连接使用 TLS，控制端在发送配对密钥前校验邀请中的主机证书指纹。

## 下载与安装

当前测试版为 [v0.1.0-beta.2](https://github.com/LuckyLivio/nnremote/releases/tag/v0.1.0-beta.2)。新版应用显示名为 **nnremote**。工程、Bundle ID 和 Windows 可执行文件名沿用初版标识。首版见 [v0.1.0-beta.1](https://github.com/LuckyLivio/nnremote/releases/tag/v0.1.0-beta.1)。

| 平台 | 要求与签名 | 安装 |
|---|---|---|
| iPhone | iOS 16+，arm64 真机。IPA 未签名。 | 用自己的 Apple 开发团队配置签名。推荐打开 `Apple/LivioRemote.xcodeproj`，在 `LivioRemote-iOS` 的 Signing & Capabilities 下设置 Team 和该团队可用的 Bundle ID，连接手机后运行。局域网直连时允许本地网络访问。 |
| macOS | macOS 14+，Apple 芯片或 Intel。应用为本地临时签名。 | 解压后移入「应用程序」。如系统拦截且已核对来源，可在「系统设置 → 隐私与安全性」中确认打开，或从源码在本机运行。共享需要屏幕录制权限，允许远端操作还需辅助功能权限。 |
| Windows | Windows 11 x64，便携包随附 .NET 桌面运行时，可执行文件未作 Authenticode 签名。 | 解压并运行 `LivioRemote.exe`。共享时按需为受信任的专用网络放行此程序。普通权限运行的主机受 UAC 和 Windows 输入权限约束。 |

本版未通过 Apple 公证，也没有 TestFlight 或 App Store 分发。可在 Release 页面查看附件来源、校验值及本版验证范围。

## 在局域网连接

1. 让两台设备进入同一个可互访的网络，共享电脑保持登录和唤醒。在 Windows 打开「共享这台电脑」，在 macOS 打开「共享这台 Mac」。确认系统授权后开始共享。Mac 上保持共享窗口和标签页打开。
2. 主机选择控制端可达的地址，默认 TCP 端口为 `47831`，选择「复制连接邀请（含密钥）」，经私密渠道传给控制端。
3. 控制端在「连接电脑」中粘贴邀请。主机确认后可选择「仅查看」或「允许控制」。首次可以打开记事本或文本编辑器，验证滚动、文本输入和停止共享。
4. 需要离开共享电脑时，可以设置「单次预授权」。新邀请可在 8 小时内使用一次。断开后要在主机重新授权。Windows 的单次授权会话还会在预设的 8 小时截止时结束。停止共享会使本轮邀请失效。

邀请内包含完整证书指纹和配对密钥，请勿公开转发。收到单次预授权邀请的人可以尝试先行使用该权限。

## 鼠标和 iPhone 手势

- macOS 和 Windows 控制端可在画面内移动指针、按住左右键拖动、双击或使用滚轮。在画面外松手时，拖动坐标限制在远端画面边缘。
- iPhone 默认使用「触控板」。单指滑动相对移动光标，轻点左击，双指滑动滚动。按住约 0.3 秒后滑动可拖动，松手结束。双击可打开项目，双指轻点为右击。
- 选择「直接触控」可按画面位置点击，按住再拖动可移动窗口或拖选。直接触控的起始点需位于画面内。手势会转换成远端的鼠标操作。
- 新旧版仍可使用同一格式的邀请，保留基本点击与滚动。两端均支持扩展指针时才启用按住拖动。仅查看会话不会转发键鼠输入。

## 网络条件与已知限制

- 局域网直连无需云服务。控制端也可使用已经可达的 IPv4、IPv6、DNS 地址或现成私网。访客 Wi-Fi 的客户端隔离、主机防火墙及网络路由可能影响连通性。
- `Link/` 是可选的手动配置中继，按邀请填写的地址接入。它转发控制端与主机之间的 TLS 数据，可观察连接时间、地址和流量大小。每个实例支持一台主机、一次一个连接。当前版本尚未实现自动异地发现、NAT 穿透或自动回退。
- 画面是低帧率单主屏 JPEG，最高 1920×1080。软键盘目前支持发送短文本和少量常用键。画面缩放、原生多点触控、完整组合键、音频、手柄、硬件编码、60 FPS、多屏和文件传输属于后续工作。
- Win32 输入受系统权限边界约束，UAC 安全桌面及部分提升权限的程序无法操作。macOS 主机需按系统提示授权屏幕录制和辅助功能。首版没有在线账号或设备同步。

## 构建与测试

Apple 使用 Xcode 打开 `Apple/LivioRemote.xcodeproj`，选择 `LivioRemote-macOS` 或 `LivioRemote-iOS` scheme。工程部署版本为 macOS 14 与 iOS 16。

```bash
xcodebuild -project Apple/LivioRemote.xcodeproj -scheme LivioRemote-macOS -configuration Release -destination 'generic/platform=macOS' build
xcodebuild -project Apple/LivioRemote.xcodeproj -scheme LivioRemote-iOS -configuration Release -destination 'generic/platform=iOS' -archivePath out/nnremote-iOS.xcarchive CODE_SIGNING_ALLOWED=NO archive
```

Windows 使用 .NET 10 SDK。在 Windows 上运行或发布：

```powershell
dotnet run --project .\Windows\LivioRemote.csproj
dotnet publish .\Windows\LivioRemote.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:EnableCompressionInSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:DebugType=None -p:DebugSymbols=false -o .\out\win-x64
```

先关闭本机桌面共享，依次运行回环测试，以免争用 TCP `47831`。Python 套件覆盖直连、证书和口令校验、IPv6、中继保留会话 TLS 以及中继重新接入。在 Mac 上还会编译并运行 Swift 测试，验证 Apple 控制端能力协商、移动合并和按钮顺序、画面坐标，以及 macOS 主机按钮事件。.NET 套件用测试画面和输入记录器运行生产 Windows 主机传输代码，验证主机批准、仅查看、断线释放和新旧协议兼容。

```bash
python3 -m unittest discover -s Tests -v
dotnet run --project Tests/WindowsHostTransport/WindowsHostTransport.csproj
```

### 实机复测

1. 在同一 Wi-Fi 使用 beta.2 连上 Windows 或 Mac 主机。允许控制后，在桌面拖动窗口，在记事本或文本编辑器拖选文字，双击文件夹并滚动长文档。
2. iPhone 分别使用触控板与直接触控，横竖屏各测一次。检查画面四角、黑边和高 DPI 主机上的落点。拖到画面外松手，指针应停在边缘，并可继续点击。
3. 在拖动中切到别的应用、使桌面控制端失焦、断开连接或在主机停止共享。每次检查主机还能正常单击和拖动。再用「仅查看」连接，确认操作不会改变主机状态。
4. 用 beta.1 与 beta.2 各作为控制端和主机互连，核对点击、滚轮和升级提示。验证结果按连接组合记录。

### 本地试用中继

先在同一台共享电脑上做回环测试。需要 Python 3.10+ 和 OpenSSL。在主机启动桌面共享后，分别在终端启动以下两条服务命令：

```bash
python3 Link/relay.py init livio-relay
python3 Link/relay.py serve livio-relay --bind 127.0.0.1
python3 Link/relay.py link 127.0.0.1 livio-relay/link.json
```

同机控制端的邀请填写 `127.0.0.1` 和 TCP `47833`。受控多设备测试需让中继侦听测试网地址，`link` 主机和控制端分别访问中继的 TCP `47832` 和 `47833`。证书私钥留在中继，`link.json` 只交给共享电脑。停止共享即可结束桌面会话。公网试用需先确认部署条件，见 [ROADMAP](ROADMAP.md)。
