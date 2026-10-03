---
id: T-206
title: Remount the tablet files volume after a server restart if it was mounted
status: review
phase: 6
owner: mac-host-dev
depends_on: [T-190]
decisions: [0028]
files:
  - host-mac/Sources/MateBridgeCore/Files/TabletFilesPlanner.swift
  - host-mac/Tests/MateBridgeCoreTests/Files/TabletFilesPlannerTests.swift
  - host-mac/Sources/MateBridgeHost/Files/TabletFilesBridge.swift  # orchestrator-approved 2026-10-03, eject wiring
  - backlog/tasks/T-206-host-files-auto-remount.md
---

## Amaç

T-190 (karar 0028) tablette paylaşılan klasörü ve salt okunur kipi ayar yaptı. Bu ayarlardan biri değişince tablet sunucuyu yeniden başlatır: önce `FILES_INFO` OFF, sonra yeni token ile READY. Mac bugün OFF'ta ya da token değişince "MatePad" birimini söküyor ama yeniden bağlamıyor; kullanıcı menüden "Tablet dosyalarını aç"ı tekrar seçmek zorunda. T-190 kartı bu durumda otomatik yeniden bağlamayı bekliyordu (Codex incelemesi, 2026-10-03). Bu kart, kullanıcı daha önce bağlamışsa Mac'in aynı oturumda yeni token ile kendiliğinden yeniden bağlamasını sağlar.

Kaynak: Codex review of T-190 (P2), `FilesController.kt` `rescope()` and `TabletFilesPlanner.swift` `filesInfo`/`openRequested`.

## Bağlam

- `TabletFilesPlanner.filesInfo`: same port + new token → `cancelPendingMount + unmount`, `mountedPath = nil`; OFF → `teardown()`. Nothing remembers that the user had mounted.
- `openRequested` is the only path that emits `.mount`.
- Wanted: a "user wants it mounted" intent that survives a server restart **within the same session** (OFF → READY with a new token, or same port + new token), and is cleared by an explicit unmount/eject by the user, by `sessionEnded`, by shutdown, and by a transport change away from USB.

## Kapsam dışı

- Wi-Fi file access, tablet-side changes, Finder UI.
- Remounting across sessions (a new session still needs the user's "Tablet dosyalarını aç").

## Kabul kriterleri

- [x] [XCTest] Mounted → `FILES_INFO` with same port and new token → unmount, then exactly one `.mount` with the new token once the forward is up (no user action).
- [x] [XCTest] Mounted → OFF → READY (new token, possibly new port) in the same session → one `.mount` after the new forward is installed.
- [x] [XCTest] Never mounted (user never opened) → restart → no `.mount`.
- [x] [XCTest] User ejected / unmounted → restart → no `.mount`. `sessionEnded` or shutdown clears the intent; a later session needs `openRequested`. _(Planner: `volumeUnmounted(path:)`, tested. The host does not call it yet — see Open questions.)_
- [x] [XCTest] A failed automatic remount does not loop: at most one automatic attempt per READY.
- [ ] [device] Mount "MatePad" in Finder, change the shared folder on the tablet (and toggle read-only): the volume comes back by itself within a few seconds with the new scope; no menu action needed.

## Plan

All in `TabletFilesPlanner` (pure); no new action, so the host bridge needs no change for the remount itself.

1. Intent `keepsMounted`: set by `openRequested` (the user asked for the volume). Cleared by `sessionStarted`, `sessionEnded`, `shutdown`, and a new event `volumeUnmounted(path:)` when the path is the volume this session mounted (user eject). `FILES_INFO` OFF, a token change and USB loss keep it (a transport change away from USB is always a new session, so session start/end cover it).
2. One automatic attempt per READY: a new READY info (one that differs from the current one, including OFF → READY) arms `autoMountArmed` when `keepsMounted`; OFF disarms it. The armed attempt fires once the forward is up: in `filesInfo` right after the unmount (same port, new token, forward already up) or in `forwardFinished` of the current generation (new forward). Firing disarms it, so a failed automatic mount sets `lastMountFailed` and waits for the next READY or the user.
3. An automatic mount does not `reveal` (no Finder window popping up on a scope change); a user `openRequested` still does.
4. Tests (Swift Testing, `TabletFilesPlannerTests.swift`): the five XCTest criteria plus: no reveal on auto mount, `volumeUnmounted` of a path that is not ours keeps the intent, armed attempt survives a failed forward (`retry`) and USB loss until it fires once.

Gap (see Open questions): the planner has no input for a Finder eject today. `volumeUnmounted(path:)` is added and tested, but calling it (e.g. from `NSWorkspace.didUnmountNotification`) is a change in `TabletFilesBridge.swift`, which is outside `files:`.

## Handoff

- **Commit:** `6827ec1` (implementation; plan in `093aa00`). Branch `task/T-206-host-files-auto-remount`.
- **Dokunulan dosyalar:** `host-mac/Sources/MateBridgeCore/Files/TabletFilesPlanner.swift`, `host-mac/Tests/MateBridgeCoreTests/Files/TabletFilesPlannerTests.swift`, this card.
- **Davranış:**
  - New private state: `keepsMounted` (user intent), `autoMountArmed` (one attempt owed for the current READY), `mountingIsAutomatic`. New public: `volumeUnmounted(path:)`, `remountsAfterRestart`.
  - Same port + new token, forward up: `[cancelMount?] + unmount + mount(newToken)` in one list. OFF → READY / port change: the mount comes from `forwardFinished` of the current generation. A failed forward keeps the attempt owed until `retry` or USB return installs it.
  - An automatic mount does not emit `.reveal` (no Finder window on a scope change). A failed one sets `lastMountFailed` and waits for the next READY or the user.
  - The existing test `mountWithAnOldTokenIsDetachedWhenItFinishes` now expects the remount (the user had opened the volume, so the token change remounts it). The stale-detach part is unchanged.
- **Varsayımlar:**
  - "Intent" starts with `openRequested`, not with a successful mount, so a restart during the user's own mount, or after a failed one, also gets its one automatic attempt.
  - USB device loss within a session keeps the intent. An attempt that was armed but not yet fired still fires once the device is back. A mount that had already been made is not remounted on USB return alone, because that is not a new READY.
  - A transport change away from USB is always a new session, so `sessionStarted`/`sessionEnded` cover it.
  - The old-token `unmount` is synchronous in the bridge (`Darwin.unmount`), so the new mount runs after it.
- **Test edilmeyenler / cihazda doğrulananlar:** nothing was run on hardware (no app launch, no mount). Device checks still needed:
  - The [device] criterion: mount "MatePad", change the shared folder, then toggle read-only on the tablet. The volume should come back by itself within a few seconds, with no Finder window popping up.
  - If the old volume is busy (an open file), the not-forced unmount fails. The remount may then land on a second mount point (`MatePad-1`), or NetFS may return an error. Check what Finder shows.
  - After a remount, opening "Tablet dosyalarını aç" from the menu reveals the remounted volume (it uses `knownPath`).
- **Açık sorular:**
  - **The Finder eject is not wired (gap).** The planner has no existing input that tells it the user ejected the volume. Its own `.unmount` actions report nothing back. So `volumeUnmounted(path:)` was added and tested, but nothing calls it yet. Until it is wired, a user who ejects "MatePad" in Finder and later changes the scope on the tablet gets the volume mounted again by itself (once per READY, silently, without a Finder window).
    - Wiring belongs in `host-mac/Sources/MateBridgeHost/Files/TabletFilesBridge.swift`, which is outside `files:`. The bridge should observe `NSWorkspace.didUnmountNotification`, hop to the bridge queue, skip the event when the path is still in `mountPoints(localPort:)`, and call `planner.volumeUnmounted(path:)`. Never log the path.
    - Proposal: widen `files:` to the bridge in this card, or open a small follow-up card.
