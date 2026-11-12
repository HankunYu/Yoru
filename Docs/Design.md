# Yoru 设计方案

> 状态:已确认方向,待 spike 验证。最后更新 2026-11-11。

## 定位

把 Linux 上那种简单强大的 mpv 装进 iPhone。不是媒体库 App:以 mpv 自身的配置体系
(`mpv.conf` / `input.conf` / `watch_later` / Lua 脚本)为中心,App 只负责选文件、
渲染、把触摸翻译成 mpv 输入。

- 自用、自签安装,不上 App Store,允许 GPL。
- 片源:本地文件、SMB、WebDAV。
- 需要:HDR、后台播放。
- 不需要:弹幕、PiP、AirPlay、媒体库刮削。
- 最低 iOS 27.1(目标机 iPhone Duo;折叠屏 API 无需可用性分支)。

## 技术栈

| 层 | 选择 |
|---|---|
| 内核 | 自维护的 MPVKit fork(GPL 变体),为 iOS 打开 LuaJIT(解释器模式) |
| 渲染 | `vo=gpu-next` + `gpu-api=vulkan` + `gpu-context=moltenvk`,`wid` 传入 `CAMetalLayer` 子类,mpv 自持 swapchain |
| 解码 | `hwdec=videotoolbox` |
| UI | SwiftUI(浏览 / 设置)+ UIKit 播放视图 + 原生极简控制层 |
| 工程 | XcodeGen(`project.yml`),真机 build/安装走 xcodebuild + devicectl |

## 模块

```
Yoru/
├─ MPVCore/        # Thin Swift wrapper over libmpv (concrete, no engine abstraction)
│   ├─ MPVPlayer   # create/initialize/destroy, command(), get/set/observe property
│   └─ MPVEvents   # wakeup cb → serial queue → mpv_wait_event → AsyncStream → MainActor
├─ Sources/
│   ├─ MediaSource # protocol: list(dir), playbackURL(item) + per-source mpv options
│   ├─ LocalSource
│   ├─ SMBSource   # libsmbclient for listing and playback (app-served stream, see below)
│   └─ WebDAVSource# listing via PROPFIND; playback via mpv-native http(s)/dav(s)
├─ Library/        # Source-agnostic: sibling subtitle matching, same-folder playlist
├─ Player/         # Metal layer view, gesture → virtual key → `keypress`, OSD split
└─ Browser/ Settings/
```

- `MediaSource` 只有 `list` 与 `playbackURL`;字幕匹配、连播由 `Library` 在 `list(parent)` 结果上统一完成,
  三种来源同一路径(本地也不依赖 `sub-auto`,mpv 对 URL 不做 sub-auto)。
- 凭据不进 URL(watch_later 以 URL 为键):WebDAV 用 `http-header-fields` 传 Authorization,
  SMB 走 libsmbclient 认证途径;凭据存 Keychain。

## mpv 配置

- `Documents/mpv/` 作为 `config-dir`,`config=yes` 在 `mpv_initialize` 前设置;
  `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` 使其在「文件」App 可见。
- 目录:`mpv.conf`、`input.conf`、`scripts/`、`script-opts/`、`fonts/`、`watch_later/`。
- 「重新加载配置」= 销毁并重建 mpv 实例(`vo`/`gpu-api`/HDR 相关选项运行时不可变)。
- 手势映射为虚拟键名(如 `TOUCH_DTAP_LEFT`)经 `keypress` 送入 mpv,绑定写在真正的 `input.conf`,
  内置一份默认绑定。默认:单击切控制层、双击左右快退快进、横滑 seek、左侧竖滑亮度、右侧竖滑 mpv `volume`、捏合缩放。
- OSD 分工:原生控制层负责进度条与按钮;mpv OSD(`show-text`、OSD bar、stats/console 脚本)负责反馈文字。

## 音频与生命周期

- 音量手势调**系统音量**(2026-11-12 用户改定,此前为 mpv `volume`):通过隐藏的 `MPVolumeView` 内部滑块设置,依赖未公开的视图结构;
  默认绑定 `script-message yoru volume <delta>`,想用 mpv 自身音量可改绑 `add volume`。系统音量 HUD 被抑制,由播放器 OSD 显示(含物理键)。
- 后台播放:`UIBackgroundModes: audio`;进后台 `vid=no` 继续出声,回前台 `vid=auto`;
  接 `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter` 锁屏控制。
- 音频会话中断(来电)、路由变化(拔耳机 → 暂停)由 App 监听处理;AO 选定 audiounit。
- 进后台 / 暂停时发 `write-watch-later-config`(iOS 没有正常 quit)。
- `mpv_terminate_destroy` 在后台线程调用。

## HDR

- 显式 `target-colorspace-hint=yes`,手动给 `target-peak` 等(moltenvk context 不上报显示参数)。
- 初始化前依据 `UIScreen.potentialEDRHeadroom` 决定 HDR 直出或 tone mapping,不依赖自动回退。
- `CAMetalLayer` 子类:主线程设置 `wantsExtendedDynamicRangeContent`,规避 drawableSize 1x1 问题;
  调试时关闭 Metal API Validation(MoltenVK #2226)。

## iPhone Duo(折叠屏)

设备参数(Apple 官方规格):内屏 7.6" 1878×2670 @430ppi,外屏 5.4" 1398×2034 @460ppi,均 120Hz ProMotion。
外屏竖屏为 compact 宽度;内屏 regular/regular,且内屏上**方向锁定会被系统忽略**。尺寸一律从 scene / 容器 view 取,
不用 `UIScreen.main`。

相关系统 API(iOS 27.1+,已在 iOS 27.2 SDK 头文件核对):

| API | 用途 |
|---|---|
| `UIHingeInteraction` → `UIHinge.status` / `angle` | 合页状态与角度;官方定位是交互与效果,不作布局依据 |
| `UIView.reservedRegions(kind: .division)` | 折痕区域(view 坐标系 `frame` + `margins` + `isActive`);仅半折时 active |
| `UIView.reservedRegions(kind: .occlusion)` | 摄像头等遮挡区域 |

- **内外屏切换不中断播放**:展开/合上是 trait 与尺寸变化,不是 scene 断开,进程持续运行。
  `CAMetalLayer` 跟随 resize,mpv 实例不重建。合上时默认继续播放(可选「合上暂停」)。
- **半折桌面模式**:有 active 的 division 区域且其为水平条带时进入。视频放折痕上方、控制层放折痕下方,
  分界取 division 区域的实际 `frame`(含 margins),**不假设在正中**。视频用 mpv 原生
  `video-margin-ratio-bottom` 推到上半(同一块 surface,不重建 swapchain)。竖直条带(书本姿态)按普通展开处理。
  在 hinge 回调与每次 layout pass 重新查询区域,不缓存。
- **遮挡区域**:全屏视频画面不避让,但控制层与 OSD 按钮避开 occlusion 区域。
- **布局按 size class 与容器尺寸自适应**,不按机型写死;内屏近方形下竖屏也是可用的观看姿态,捏合缩放 / `panscan` 对裁边有用。
- 状态抽成 `PostureMonitor`(Player 模块内):输入 hinge 状态 + division 区域,输出 `flat / tabletop(foldRect) / closed`,
  播放视图只消费 posture,不直接碰 `UIHinge` 与 reserved region。

## Spike(M0)验证清单

1. Fork 的 MPVKit 带 LuaJIT 能在 iOS 构建并运行内置脚本(stats / console / auto_profiles)。
2. Vulkan + `wid` 真机出图,VideoToolbox 硬解生效;旋转后尺寸正确。
3. HDR 片源触发 EDR。
4. libass 中文 ASS 无豆腐块(CoreText provider 或 `fonts/` 内置字体)。
5. libsmbclient 播放 SMB 大码率片源的吞吐与 seek。
6. 本地文件 watch_later 键在 App 更新/重装后是否稳定,据此决定路径策略。
7. iPhone Duo:展开/合上时 resize 不黑屏不重建;半折时 division 区域的实际位置与激活时机。

### Spike 结果(2026-11-11,iPhone Duo / iOS 27.3)

| 项 | 结果 |
|---|---|
| 1 Lua | ✅ stats 面板可弹出(MPVKit 全平台开 `-Dlua=luajit`) |
| 2 出图 / 硬解 | ✅ gpu-next + moltenvk,`hwdec=videotoolbox`(H.264 nv12 / HEVC p010) |
| 2 旋转 / 折叠 resize | ✅ 补丁 `0004-moltenvk-surface-size`:新增 mpv 选项 `moltenvk-surface-size`(对应上游 `android-surface-size`),App 每次布局后上报像素尺寸;暂停时也正确重绘。KVO 监听 `drawableSize` 不触发,不可用 |
| 3 HDR | ✅ HDR10 4K 40M 样片触发 EDR |
| 4 中文字幕 | ✅ 需内置字体:沙盒下 libass 打不开系统字体,且每帧重试导致严重卡顿;内置 Noto Sans CJK SC 到 `fonts/` 并设为 `sub-font` |
| 5 SMB | ✅(经「文件」App)原地打开拿到的是系统挂载路径 `/private/var/mobile/Library/LiveFiles/com.apple.filesystems.smbclientd/<挂载ID>/…`,按需读取、秒开、可 seek,不是整文件下载。mpv 原生 `smb://`(libsmbclient)未测 |
| 6 watch_later | ✅ 续播生效;重装后路径稳定性未测 |
| 7 Duo 折叠 | ✅ 展开/合上画面正确;内屏竖屏 division 区域 `(0,455,669,41)`,平放时 inactive。半折桌面模式待测 |

过程中确定的约束:

- **主线程不得同步调用 mpv**:渲染线程会 `DispatchQueue.main.sync` 去开 EDR,同步调用会死锁。`MPVPlayer` 只暴露 async 命令/写属性,读属性一律走 observe。
- MPVKit 需显式 `-Dx11=disabled`(Homebrew 的 libX11 会经 pkg-config 混入)。
- 真机构建需 `-destination id=<Duo>` + `-allowProvisioningDeviceRegistration`。

### Spike 之后的方案修订(2026-11-11,用户确认)

- **渲染分辨率用 `UIScreen.nativeScale`**,不用 UIKit 的 displayScale:理由是按物理像素渲染、避免系统二次缩放
  (MPVKit 官方 Demo 同样用 nativeScale)。**未经验证**:Duo 内屏 nativeScale 的实际值尚未在设备上读到;
  用户曾反馈的锯齿后确认是片源问题,与此改动无关。
- **SMB 两条路都做**:
  - A 系统挂载:用文件夹选择器对「文件」App 里已连接的 SMB 目录取一次授权(security-scoped bookmark),
    之后按本地目录浏览。与 `LocalSource` 共用实现,只是根目录不同。挂载 ID 重连后会变,续播键需处理。
  - B 自带 SMB(已实现,见文末「SMB browsing」):libsmbclient 同时负责列目录和播放,凭据存 Keychain,
    不依赖「文件」App。libsmbclient 在 iOS 沙盒内可用(已在设备上验证浏览)。
- **打开方式**:声明 `public.movie` / `public.audio` + 21 个 iOS 未声明的容器类型(mkv、webm、rmvb、ape 等),
  原地打开不复制。`iso`(蓝光/DVD 镜像)需走 `bd://`,未做。

### 待办(用户已确认,后续做)

- 进度条拖动精度可配置:默认拖动中关键帧跳转(`absolute+keyframes`)、松手精确;可切换为拖动中也精确(对应 osc 的 `seekbarkeyframes`)。

## 里程碑

- **M0** spike(上表)。
- **M1** 工程骨架、本地播放、手势 + OSD、`mpv.conf`/`input.conf`、后台播放、内外屏切换。
- **M2** SMB + WebDAV 浏览与播放、服务器管理(Keychain)、同目录字幕。
- **M3** HDR 调优、音轨/字幕/倍速菜单、续播、同目录连播、半折桌面模式。

## Browser: grid, list and thumbnails

The browser shows a directory as a grid (default) or a list, sorted by name, date or size;
both choices are app UI state in UserDefaults. One `UICollectionView` serves both layouts.

- **Thumbnails** come from libmpv itself, since AVFoundation cannot read mkv: `ThumbnailRenderer`
  runs a short-lived offscreen instance (`vo=libmpv`, software render API, software decoding,
  `start=10%`) and reads duration, resolution and transfer function in the same pass.
- **Cache**: `MediaPreviewStore` keeps a 640x360 JPEG and a JSON of the facts per file in
  `Library/Caches/Previews`, keyed by path, size and modification date. Generation is serial
  and suspended while the player is open.
- **Resume progress**: `WatchHistory` parses `watch_later`; the player sets
  `write-filename-in-watch-later-config` so each entry names its file.
- **Folders** show their first three files' thumbnails as a stack of cards.
- Only local files get thumbnails; network locations are out of scope until M2.

## SMB browsing

Saved servers are listed on the root screen and browsed with the same grid and list as
local files. This replaces the earlier plan of libsmb2 listing plus mpv-native `smb://`.

- **One library**: libsmbclient, already part of the GPL MPVKit build, lists shares and
  directories (`SMBConnection`) and reads files for playback (`SMBStream`).
- **No credentials in URLs**: items are addressed as `yoru-smb://<server id>/<share>/<path>`.
  mpv opens that scheme through libmpv's `stream_cb` (`MPVStreamProtocol`), and the app
  looks the login up when connecting. An `smb://user:pass@host` URL would have put the
  password into mpv's log and the `watch_later` files in Documents.
- **Storage**: `ServerStore` keeps name, host and username as JSON in Application Support;
  passwords are Keychain items (`AfterFirstUnlock`, so background playback can reconnect).
- **Connections**: a libsmbclient context is not thread-safe. Browsing uses one context per
  server on its own serial queue (`SMBSession`); each playing file has its own context.
- **Module**: MPVKit's `Libsmbclient` module is an umbrella over headers that need
  `talloc.h` and cannot be imported, so `Vendor/CSMBClient` exposes `libsmbclient.h` alone.
- **Discovery**: Bonjour `_smb._tcp` via `NWBrowser`; the host name comes from
  `DNSServiceResolve`, since the service's display name is not an address.
- **Subtitles**: mpv scans for same-folder subtitles only for local files, so the browser
  passes matching siblings to the player, which attaches them with `sub-add`.
- **Limits**: remote items have no thumbnails, cannot be deleted, and folders show no item
  count. Saved servers cannot be edited, only removed and added again.
- **Not yet verified on device**: playback throughput and seeking on high-bitrate files,
  subtitle attachment, resume.
