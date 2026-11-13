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
- **半折桌面模式**(已实现,见文末「Half-folded layout」):有 active 的 division 区域且其为水平条带时进入。视频放折痕上方、控制层放折痕下方,
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
- **HDR**: the software renderer leaves pixels in the video's transfer function. PQ is
  converted by `HDRToneMap` (SDR white at 100 nits, highlights rolled off); Core Graphics'
  own conversion puts white at 203 nits and looked gray. HLG still goes through Core Graphics.
- **Placeholders**: files without a thumbnail (everything remote) show a symbol and color
  for their `MediaKind`, judged by extension, over the extension itself. Subtitles and
  unknown types are dimmed and do not open.
- **Cache**: `MediaPreviewStore` keeps a 640x360 JPEG and a JSON of the facts per file in
  `Library/Caches/Previews`, keyed by renderer version, container-relative path, size and
  modification date (the absolute container path changes on every reinstall). Generation is serial
  and suspended while the player is open.
- **Resume progress**: `WatchHistory` parses `watch_later`; the player sets
  `write-filename-in-watch-later-config` so each entry names its file.
- **Resume across reinstalls**: mpv names a resume file by the MD5 of the absolute path, and
  the app's container path changes on every reinstall. At launch `ResumePositions.rebase`
  rewrites entries that point into an old container (keeping the newest per file) and
  deletes mpv's redirect entries, which only serve directory playback.
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

## Settings pages

Settings opens on a list of categories (Playback, Video, Audio, Subtitles, Gestures,
Cache & Storage), then the configuration file editors. Every option is still one line of
`mpv.conf` or `script-opts/yoru.conf`.

- **Gestures come from options**: the built-in touch bindings are generated by
  `TouchBindings` from `yoru.conf` (`double-tap-seek`, `brightness-gesture`,
  `volume-gesture`, `swap-gesture-sides`, `hold-speed`) instead of a bundled `touch.conf`.
  Bindings in the user's `input.conf` still win.
- **Close at end**: `keep-open=no` makes the player close itself on end-of-file.
- **Not possible yet**: volume normalization. The FFmpeg build has no dynamics or
  loudness filter; it needs `--enable-filter=dynaudnorm` (or similar) in the MPVKit fork.

## Half-folded layout

Half-folded on the inner display (an active division region), the player asks for
portrait, either way up, so the fold lies across (`OrientationLock`, applied in the app
delegate because SwiftUI owns the presenting controllers).

- **Split**: with a horizontal fold the picture takes the upper half through mpv's
  `video-margin-ratio-*`, and `SplitControlPanel` takes the lower half: title, seek bar,
  transport, and subtitle / audio / speed tiles showing their current values. It does not
  auto-hide, and the picture gets no scrims.
- **Gestures**: on the picture as usual. The panel's empty space takes vertical drags only
  (brightness, volume), recognized in SwiftUI behind its controls, because the panel's
  hosting view swallows touches before they reach the player view.
- **Not pinned to a physical half**: the picture is always the upper half on screen.
- **Open**: using the outer display propped up like a tent; which display the system lights
  in that posture, and what the player should do, are undecided.

## Adjustments panel

A second-level panel (`AdjustmentPanel`) for what is tuned while watching, opened from the
quick panel; the track and speed menus stay one tap away beside it. Four tabs: subtitles
(delay, size, position, visibility, second subtitle), audio (delay, volume boost up to
`volume-max=200`), picture (aspect, rotation, equalizer, debanding) and playback (fine
speed, A-B loop).

- **Placement**: a trailing drawer on a wide view, a bottom sheet on a tall one, and the
  controls' half when half-folded. It replaces whichever controls would show, and a tap on
  the picture dismisses it. Playback continues, so changes are judged against the picture.
- **State**: `PlayerNumber` and `PlayerFlag` name the mpv properties behind the controls;
  `PlayerModel` mirrors them and writes back optimistically.
- **Persistence**: `watch-later-options` keeps the position, tracks, subtitle visibility
  and the two delays per file (`start` must be listed in this mpv version). Everything else
  lasts for the playback; subtitle size and position can be written to `mpv.conf` as the
  default from the panel.
- **Resume safety**: mpv deletes a resume file when the file is opened and rewrites it on
  quit, so the app also saves every 20 seconds and whenever it stops being active.

## Folder playback, endings and first subtitles

- **Queue**: a file opened from the browser carries a `PlaybackQueue`: the files of its
  kind in its folder, in the browser's order. Previous and next load into the running
  player; `reset-on-next-file` clears track choices, delays and loop points between files.
- **At the end**: `at-end` in `yoru.conf` is `next` (default), `stay` or `close`. mpv keeps
  the last frame (`keep-open`) and the app acts on `eof-reached`.
- **Finished files**: a position at the end or in the last stretch (5% of the duration,
  between 10 seconds and 3 minutes) is not saved, and an earlier resume file is deleted, so
  a finished file starts over.
- **First subtitle**: subtitles the app supplies carry no language, so mpv's `slang` cannot
  pick them. On a first viewing `SubtitleChooser` ranks them by the language tag in their
  file name against the preferred languages and switches when an external one fits better.
- **Loading**: from opening a file to its first frame the picture shows a spinner and the
  rate measured on app-served streams (`MPVStreamMeter`); mpv's `cache-speed` only starts
  once its cache does.
- **Adjustments panel**: slides in from the trailing edge or the bottom and can be dragged
  away. It keeps one margin to every display edge, ignores the safe area and steps aside
  only for an occlusion that overlaps it, and its outline is concentric with the display.

## Servers: WebDAV, editing and thumbnails

- **One server model**: `MediaServer` has a kind (`smb`, `webdav`), a name, an address
  (the host for SMB, the base URL for WebDAV) and a username; the password stays in the
  Keychain. Each kind has its own URL scheme, `yoru-smb` or `yoru-dav`, followed by the
  server's identifier, so browser URLs never hold an address or a login.
- **Playback is the source's business**: `MediaSource.playback(of:)` returns what mpv
  gets. SMB hands over the browser URL, served by the app. WebDAV hands over the file's
  real URL plus an `Authorization` header (`http-header-fields`), and mpv plays it over
  its own HTTP. The header is replaced on every load, so it never reaches another server.
- **WebDAV listing**: `WebDAVClient` sends PROPFIND with depth 1 and HTTP Basic up front.
  Plain HTTP is allowed (`NSAllowsArbitraryLoads`), as home servers often have no TLS.
- **Editing**: `ServerEditorView` adds or edits; an empty password field keeps the stored
  one, and the server is saved only after a listing with the entered values succeeds.
- **Remote thumbnails**: `ThumbnailRenderer` registers the app's stream protocols and
  headers on its offscreen instance, so videos on servers get thumbnails too
  (`remote-thumbnails` in `yoru.conf`). A remote file that never opened is not cached as
  having no picture, since the network may have been the reason.

## Contents panel, subtitle look and system integration

- **Side panel**: the second-level panel holds either the adjustments or the contents
  (`SidePanelContent`). Contents is two lists, the folder's playlist and the file's
  chapters; chapter starts are also marked on the seek bar.
- **Subtitle look**: color, outline, shadow, bold and background box are plain mpv
  properties (`PlayerNumber`, `PlayerFlag`, `PlayerText`). Subtitles with their own styling
  ignore them unless `sub-ass-override=force`. "Use This Look as Default" writes the set
  to `mpv.conf`.
- **Now playing**: mpv's audio output mixes with other apps unless `audio-exclusive=yes`,
  and a mixing app never becomes the system's now-playing app, so that option is what makes
  the lock screen and Control Center work at all. Artwork is the browser's thumbnail.
- **Surface size before loading**: mpv's Vulkan context refuses to configure a surface of
  unknown size (`moltenvk-surface-size`), which fails the whole video chain. The player
  view is laid out before the player starts, so the size is sent ahead of `loadfile`; a
  small local file otherwise decodes its first frame first.
- **mpv saves on `loadfile` too**: with `save-position-on-quit`, loading a file over
  another writes the outgoing one's resume file. For a finished file the option is turned
  off across the load, or the entry just deleted would come back.
- **User scripts**: verified on the device that a Lua script in `mpv/scripts/` is loaded,
  receives events and reads properties.

## Library management, downloads and bookmarks

- **One transfer queue**: `FileTransfers` (app-wide) copies files into the library one at
  a time: imports from other apps and downloads from servers alike. Its progress bar,
  with a measured rate, sits over the whole browser, so a transfer outlives the screen
  that started it. Each source says how one of its files is fetched
  (`MediaSource.transfer(of:)`). Cancelling stops the running copy (a detached task does
  not inherit cancellation; it is passed on by hand) and any folder walk still feeding it.
- **Download plan**: servers cannot report a folder's size, so `DownloadPlan` walks the
  selection with one listing per folder, counting while the destination sheet is open and
  queuing as it goes once a destination is chosen. Folders merge into existing ones and a
  file already present with the same size is skipped, so a cancelled download resumes at
  file granularity; a size mismatch is replaced.
- **Local files**: new folder, rename, move (`FolderPicker`), and a selection mode for
  batch move, delete and download. Items offer their actions through `BrowserAction`.
- **Bookmarks**: `BookmarkStore` keeps shortcuts to folders, local (stored relative to
  Documents) or on a server; they appear on the root screen and go when their server does.
- **Telling files apart**: images carry a symbol where videos show their duration, and a
  filter hides everything but video and audio. Only JPEG counts as an image: it is the one
  image format this FFmpeg build decodes.

## iPad, keyboards and narrow or notched displays

- **iPad**: enabled for both idioms and tested in the simulator only (launch, browser,
  playback, control layout). The foldable APIs need iOS 27.1, hence a 27.2 simulator runtime.
- **Keyboard**: presses reach mpv as `keydown` / `keyup` under mpv's own key names
  (`KeyboardInput`), so default bindings and input.conf apply; mpv quitting closes the player.
- **Occlusions come in three shapes**: a block in a corner (the outer display's camera) is
  stepped around by the rows it overlaps; a strip down a whole side (the Dynamic Island in
  landscape) insets both sides alike, keeping rows centered; a strip across the full width
  (an iPad's status bar) is ignored, as nothing fits beside it.
- **Narrow bottom bar**: where the seek capsule and the quick panel do not fit side by
  side, the quick panel moves to a row above the seek bar (`ViewThatFits`).
- **Split panel gestures**: the controls' half of a half-folded display takes the picture's
  gestures on its empty space, all but the single tap, through the same bindings.

## Tests, file info and the fork's FFmpeg

- **Unit tests**: the `YoruTests` target covers logic that needs no device: config file
  editing, subtitle choice, resume file re-keying, download planning, media kinds, sorting,
  server addresses, bookmarks, WebDAV parsing, touch bindings, HDR tone mapping and typed
  times. They run in a simulator in under a second. What involves a live mpv or the
  transfer queue's background work is not covered.
- **File info**: `InfoPanel` shows container, codecs and formats in a readable form, from
  properties observed as strings. mpv's statistics overlay stays for diagnosing playback;
  its menu item mirrors the on/off state itself, since mpv's script does not report it.
- **Diagnostics** (layer, display, fold state) is a troubleshooting aid, offered in the
  menu only when `diagnostics=yes` in `yoru.conf`.
- **Jump to time**: seconds, `m:ss` or `h:mm:ss`, seeking exactly.
- **FFmpeg from the fork**: the fork now builds FFmpeg too (release `yoru-0.41.0-2`),
  adding the PNG, APNG, WebP, GIF, BMP and TIFF decoders, GIF and APNG demuxers, and the
  dynaudnorm, loudnorm, acompressor, cropdetect and crop filters. Images follow that list;
  HEIC, JPEG XL and AVIF are not decoded. No volume normalization switch exists yet.

## Streams served to mpv

- **Every `smb://` goes through the app.** Pasted links are registered as a stream
  protocol too, ahead of mpv's own handler, so all libsmbclient use sits behind
  `SMBConnection`'s lock. A link must name a file; servers and shares are browsed by
  adding the server.
- **`BlockCachedStream`** wraps every app-served stream: 1 MB blocks, the 8 most recently
  used kept. A seek only moves a position. Needed for files whose audio and video are
  not interleaved: FFmpeg seeks between the two regions for nearly every packet and,
  for non-local input, refills a buffer of up to 16 MB after each seek.
- **WebDAV is served by the app too** (`WebDAVStream`): one range request per read on a
  kept-alive connection, behind the same block cache. FFmpeg's own HTTP reconnects on
  every seek. The server must honor `Range`. Files are identified as
  `yoru-dav://<server id>/<path>`, like SMB, so no login is handed to mpv.
- **Streams can be cancelled** (`MPVStreamSource.cancel`, libmpv's `cancel_fn`), so
  closing the player does not wait for a stalled request.
- **Images are recognized by content** (fork release `yoru-0.41.0-3` adds FFmpeg's image
  pipe demuxers); before, mpv chose the decoder from the file extension alone.
- **Remembered thumbnail failures expire** when `MediaPreviewStore.decoderGeneration`
  changes; bump it whenever the fork's FFmpeg gains formats.

## Seek bar and thumbnail cache

- **Dragging the seek bar is relative**: the position moves from where it is by the
  finger's travel, a full bar being the whole duration. Position and bar width are taken
  when the drag starts. A touch that does not move does nothing.
- **The bar keeps its length**: the position label reserves the duration label's width.
  Fills and chapter marks are clipped to the track's capsule.
- **The thumbnail cache is capped** at 400 MB, least recently shown first, trimmed to 80 %
  at launch and every 64 writes.
- **Home** in the browser: local subfolders go back to the root, server folders to the
  server's top. Open Location is offered at the root only.

## HDR output on iOS

- **The layer asks for HDR itself.** MoltenVK only gives `MetalLayer` the color space of
  the surface mpv chose; mpv's code that turns EDR on exists for macOS alone. `MetalLayer`
  watches its `colorspace` and, for an HDR one, sets `wantsExtendedDynamicRangeContent`,
  `preferredDynamicRange = .high` and `contentsHeadroom` (the request since iOS 26).
  Without it the picture is clipped at SDR white unless another app has the display in HDR.
- **The system fits the highlights.** The layer carries `CAEDRMetadata` (HDR10 with a peak
  of 1000 nits and white at 100, or HLG), so the system maps to what the display can show
  at its current brightness. mpv renders to the same peak (`target-peak`, set while the
  output is HDR): left on auto it takes PQ output to reach 10 000 nits and scales HLG up
  to that. A file's own mastering peak is not used; it is often a placeholder.
- **Subtitles** are drawn at 100 nits in HDR output (`sub-hdr-peak`,
  `image-subs-hdr-peak`), the white of the interface.
- **Dolby Vision** profiles 7 and 8 play by their base layer (`vf format=dolbyvision=no`):
  HDR10, or HLG in what iPhones record. Profile 5 keeps the processing.

## Thumbnails and large video

- The software renderer draws frames as decoded, so thumbnails set `video-rotate=no` and
  are turned in the app; it applies no Dolby Vision either, so they use the base layer
  and read the color description after the filters (`video-out-params`). HLG is read as
  plain BT.2020, which is what its design allows for.
- A hook (`on_preloaded`) learns the picture's size before anything is decoded. Up to 4K:
  software. Beyond, H.264 and HEVC: the hardware decoder only, one video at a time. Other
  codecs beyond 4K: no thumbnail. Stills are always decoded.
- Starting the player abandons thumbnails in progress; they are made again afterwards.
- `PlaybackMemory`: playing holds about 36 frames. A video whose frames would take more
  than 80 % of the app's memory limit (about 3.4 GB on an iPhone) is stopped with a
  message instead of letting the system end the app.
- Streams: a stream's cookie stays valid until its registration goes, because mpv may
  call `cancel_fn` while and after closing the stream.

## Smaller things

- Volume normalization (`normalize-volume` in `yoru.conf`, a labeled `dynaudnorm` filter).
- A pinch switches between fit and fill; it no longer zooms.
- Settings is in the toolbar of every folder.

## Search

- Each folder has a search bar. Typing filters the folder shown; the scope "Subfolders"
  walks everything below it (`FolderSearch`, breadth first, one listing at a time,
  cancelled when the text or scope changes, at most 3000 folders).
- A query is its words, all of which must be in the name; case, width and accents aside.
- Results from below carry their path (`BrowserItem.context`), shown in the detail line.
- Previous and next lead through the results. Each result's subtitles are still looked
  for in its own folder: the walk keeps every listing it made (`PlaybackQueue.listings`).
- At the root, "Subfolders" covers local files only; a server is searched from inside it.

## Blu-ray folders (BDMV)

- **The app reads the disc.** mpv's `bd://` takes a local path only. A folder holding
  `BDMV` is shown as its titles (`DiscView`): the playlists in `BDMV/PLAYLIST` are read
  through the folder's own source (`MediaSource.data(of:)`) and parsed
  (`BlurayPlaylist`), and a title is played as an inline EDL of its clips, each with its
  start and length in the clip's own timestamps. So a disc on a server plays like a
  local one. No menus, no encrypted discs, no ISO images.
- **Per-file options for a title**: `load-unsafe-playlists=yes`, since mpv keeps an EDL
  from opening app-served streams (it reports that as "no protocol handler");
  `demuxer-lavf-probesize` of 24 MB, since some discs carry stream tables with wrong
  checksums, which FFmpeg accepts only after a dozen sightings and until then guesses,
  losing PCM audio; `force-media-title`.
- **Chapters** come from the playlist's marks and are written to mpv's `chapter-list`
  once the file is loaded (`MPVPlayer.setProperty(_:node:)`); the EDL has `!no_chapters`.
- **What is offered**: playlists of a minute or more, without those that replay their
  clips (decoys) and duplicates. Titles at least ten minutes long and 60 % of the longest
  are features, the rest extras, each in the disc's own order.
- **Names**: `BDMV/META/DL/bdmt_*.xml` may name the disc and its titles by title number;
  `BlurayIndex` follows `index.bdmv` and `MovieObject.bdmv` from a number to its
  playlist where the program plays one outright. Most discs name nothing, and titles are
  then "Main Feature", "Feature n", "Extra n".
- **Streams**: the playlist's stream table gives video format, audio codecs and the
  languages the clips leave out. The row shows them; in the player they are given to
  mpv's tracks by order, and on a first viewing the language preferences pick among them.
- **Subtitles**: files beside `BDMV` named after the disc folder (`Film/Film.chs.ass`),
  loaded for features only.
- **Frames**: each title is pictured by its longest clip, made as its row comes into view.

## Shaders

- **What they are**: `.glsl` files in mpv's hook format, `.cube` color tables, and `.group` files, text listing shader names, so several are switched as one (an Anime4K mode is half a dozen files). `ShaderLibrary` is the one place that knows where they are.
- **Two sources**: `Documents/mpv/shaders` holds the user's; `App/Resources/Shaders` ships built-in ones in the app bundle, read-only and replaced by updates. A file in the user's folder stands in for a built-in shader of the same name: editing a built-in one writes that file, and "Restore Original" removes it. Built-in ones are not copied to Documents on first launch, as the default config is, because then an update could not improve them.
- **Built-in shaders** are creative looks, written for the app: CRT television, VHS tape, handheld console. Their titles are translated (keys added by hand, `extractionState: manual`); the user's shaders show their file names. They hook `OUTPUT` and size their features in screen pixels or as counts down the picture, never in source pixels: on a dense phone screen a scanline a few pixels high cannot be seen. They are tuned for SDR.
- **In the player** (Adjustments > Picture): groups as exclusive switches, single shaders in the order they were switched on, a color table picker. The selection is kept in `yoru.conf` (`shaders`, `shader-group`, `color-table`). A group that is on is read again at each attach, so editing it changes what plays.
- **In Settings > Shaders**: groups (reorder, rename, duplicate), built-in and imported shaders, import. A shader's page lists its `#define NAME number // comment` lines as editable values (`ShaderSource`), edits the source, and runs `ShaderCheck`: a second of bundled video through an off-screen gpu-next with only that shader on, showing what the renderer objected to, since mpv otherwise drops a broken shader silently.
- **Tests** check every built-in shader compiles (`ShaderCheckTests`).
