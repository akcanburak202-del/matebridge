# host-mac — agent rules

Mac side: virtual display, capture, encoding, network server, input injection, menu bar app.

## Stack

- Swift 6 (language mode 6, strict concurrency), **Swift Package Manager only**. There is no `.xcodeproj`, because project files cause merge conflicts between agents (decision 0002).
- Minimum macOS 15. The real target is macOS 27 on Apple M6.
- Frameworks: ScreenCaptureKit, VideoToolbox, CoreGraphics (CGEvent), Network.framework, os.Logger. No third-party packages without a decision record.

## Layout (grows as tasks land)

```text
host-mac/
├── Package.swift
├── Sources/
│   ├── MateBridgeCore/     # pure logic: protocol codec, geometry, input state; no UI, fully unit-tested
│   ├── MateBridgeHost/     # capture, encoder, virtual display, injector, network
│   └── MateBridgeApp/      # menu bar app entry point (thin)
├── Tests/MateBridgeCoreTests/
└── Resources/              # Info.plist, entitlements
```

## Commands

```bash
cd host-mac && swift build
cd host-mac && swift test
../scripts/bundle-host.sh   # wraps the binary into MateBridge.app and signs it (added in a later task)
```

## Rules

- Anything testable without hardware goes in `MateBridgeCore` and gets unit tests (protocol encode/decode against `protocol/fixtures/`, coordinate transforms, key maps).
- `CGVirtualDisplay` (private API) lives only in `VirtualDisplay.swift`. Keep the retained object alive, because the display disappears when it is deallocated.
- Capture, encode and network work runs on dedicated queues or actors, never on the main actor.
- CGEvent posting requires Accessibility permission, and capture requires Screen Recording. Detect both and report them clearly. Never crash when one is missing.
- The app must be signed with the same identity on every build, otherwise macOS resets TCC permissions.
- Tablet pen events: send proximity enter/leave, then mouse events with `kCGEventMouseSubtypeTabletPoint` carrying pressure (0–65535) and tilt. Reference: `LukeLogix/android-display` (Apache-2.0). If you adapt code from it, credit it in a comment.
