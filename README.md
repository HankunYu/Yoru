# YORU

A video player for iPhone built on [mpv](https://mpv.io), in the spirit of IINA: open a file
and play it, with mpv's formats, options and scripting underneath and a native interface on
top. It is a personal project, built for and tested on one device (an iPhone Duo), and is
installed by building it yourself; it is not on the App Store.

## What it does

- Plays what mpv plays: mkv, mp4, webm, rmvb and the rest, HEVC / AV1 with hardware
  decoding, HDR output, ASS subtitles.
- Local files (imported, or opened in place from the Files app), SMB and WebDAV servers,
  and http / https / ftp / rtsp / rtmp addresses.
- Touch gestures that are ordinary mpv key bindings (`GESTURE_*` in `input.conf`), a panel
  for subtitle, audio, picture and playback adjustments, and a split layout when the
  device is half-folded.
- `mpv.conf`, `input.conf`, fonts and Lua scripts live in `mpv/` inside the app's folder in
  the Files app, in the same layout as `~/.config/mpv`. Settings edits those same files.
- Resume per file, playing on through a folder, thumbnails, background audio.

## Building

Requirements: Xcode with the iOS 27.1 SDK, [XcodeGen](https://github.com/yonaskolb/XcodeGen),
and a device (the project is not set up for the simulator).

```sh
xcodegen generate
xcodebuild -project Yoru.xcodeproj -scheme Yoru -configuration Debug \
  -destination generic/platform=iOS -allowProvisioningUpdates build
```

Set your own `DEVELOPMENT_TEAM` and bundle identifier in `project.yml` first.

libmpv comes from [a fork of MPVKit](https://github.com/HankunYu/MPVKit/tree/yoru) that
enables LuaJIT on iOS and carries two small libmpv patches (a surface-size option for
host-driven resizing, and the `GESTURE_*` key names). The GPL build is used.

## Layout

- `App/` — the app. `MPVCore` wraps libmpv, `Player` is the playback screen, `Browser` the
  file and server browser, `Network` SMB and WebDAV, `Media` thumbnails and resume files,
  `Config` the readers and writers of the config files, `Settings` the settings screens.
- `Docs/Design.md` — design notes: decisions, what was verified on the device, and why
  things are the way they are.
- `Vendor/CSMBClient` — a module map exposing `libsmbclient.h`.
- `Design/` — app icon drafts.

## Third-party

mpv, FFmpeg and libsmbclient (through MPVKit), libass, libplacebo, MoltenVK and LuaJIT.
The bundled subtitle font is Noto Sans CJK SC (SIL Open Font License).
