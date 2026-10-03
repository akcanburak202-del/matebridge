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
- [x] [XCTest] User ejected / unmounted → restart → no `.mount`. `sessionEnded` or shutdown clears the intent; a later session needs `openRequested`. _(Planner: `volumeUnmounted(path:mountedNow:)`; bridge: `NSWorkspace.didUnmountNotification`.)_
- [x] [XCTest] A failed automatic remount does not loop: at most one automatic attempt per READY.
- [ ] [device] Mount "MatePad" in Finder, change the shared folder on the tablet (and toggle read-only): the volume comes back by itself within a few seconds with the new scope; no menu action needed.

## Plan

All in `TabletFilesPlanner` (pure); no new action, so the host bridge needs no change for the remount itself.

1. Intent `keepsMounted`: set by `openRequested` (the user asked for the volume). Cleared by `sessionStarted`, `sessionEnded`, `shutdown`, and a new event `volumeUnmounted(path:)` when the path is the volume this session mounted (user eject). `FILES_INFO` OFF, a token change and USB loss keep it (a transport change away from USB is always a new session, so session start/end cover it).
2. One automatic attempt per READY: a new READY info (one that differs from the current one, including OFF → READY) arms `autoMountArmed` when `keepsMounted`; OFF disarms it. The armed attempt fires once the forward is up: in `filesInfo` right after the unmount (same port, new token, forward already up) or in `forwardFinished` of the current generation (new forward). Firing disarms it, so a failed automatic mount sets `lastMountFailed` and waits for the next READY or the user.
3. An automatic mount does not `reveal` (no Finder window popping up on a scope change); a user `openRequested` still does.
4. Tests (Swift Testing, `TabletFilesPlannerTests.swift`): the five XCTest criteria plus: no reveal on auto mount, `volumeUnmounted` of a path that is not ours keeps the intent, armed attempt survives a failed forward (`retry`) and USB loss until it fires once.

Gap found in the first pass: the planner had no input for a Finder eject. The orchestrator approved adding `TabletFilesBridge.swift` to `files:` on 2026-10-03 for the eject wiring.

5. Eject wiring: the bridge observes `NSWorkspace.didUnmountNotification`. It hops to the bridge queue and calls `planner.volumeUnmounted(path:mountedNow:)` with our mount points on the current forward. It removes the observer at shutdown and in `deinit`. The decision is pure and tested in the planner. An unmount counts as an eject only when the path is the current `mountedPath` and is no longer in `mountedNow`.

## Handoff

- **Commit:** `6827ec1` (remount) and `15f5a4a` (eject wiring). The plan is in `093aa00`. Branch `task/T-206-host-files-auto-remount`. `./scripts/check.sh` ALL OK (host: 784 tests).
- **Dokunulan dosyalar:** `host-mac/Sources/MateBridgeCore/Files/TabletFilesPlanner.swift`, `host-mac/Tests/MateBridgeCoreTests/Files/TabletFilesPlannerTests.swift`, `host-mac/Sources/MateBridgeHost/Files/TabletFilesBridge.swift` (orchestrator-approved), this card.
- **Davranış:**
  - New private state: `keepsMounted` (user intent), `autoMountArmed` (one attempt owed for the current READY), `mountingIsAutomatic`. New public: `volumeUnmounted(path:mountedNow:) -> Bool`, `remountsAfterRestart`. New internal: `samePath`, which ignores a trailing slash, because a NSWorkspace URL path and a `getfsstat` mount point may differ by one.
  - Eject detection: the bridge observes `NSWorkspace.didUnmountNotification` (`volumeURLUserInfoKey`) on the posting thread, then `queue.async`. It computes `mountPoints(localPort:)` for the current forward and calls the planner. When the planner accepts the eject, the bridge logs `ev=eject remount=off`, without the path. The observer is removed at the start of `shutdown()` and in `deinit`.
  - Our own unmounts never count as an eject:
    - Teardown and a token change clear `mountedPath` before they emit `.unmount`.
    - A stale `.unmountPath` is never the current path.
    - A late notification that arrives after the remount has landed on the same mount point is ignored, because that path is in `mountedNow`.
    - Tested: `lateNotificationOfOurUnmountAfterTheRemountLandedOnTheSamePathIsIgnored`, `notificationsOfTeardownAndStaleUnmountsAreNotEjects`.
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
  - **Eject:** mount "MatePad", eject it in Finder, then change the shared folder on the tablet. There must be **no** remount. The log should show `ev=eject remount=off` once.
  - **Remount with no false eject:** with the volume mounted, change the scope. The volume comes back, and a further scope change remounts it again. This shows that our own unmount's notification was not taken as an eject.
  - Check that `NSWorkspace.didUnmountNotification` really arrives for a NetFS WebDAV volume, in a menu-bar app with no windows, with `volumeURLUserInfoKey`. This is expected, but it is not verified here.
- **Açık sorular:**
  - **Remaining race (rare):** the user ejects the volume, and before the bridge queue handles the notification, a server restart arrives. The restart clears `mountedPath`, so the eject is not recognized, and that one READY remounts silently. Closing this would need the bridge to report what `.unmount(localPort:)` found (no volume means it was already ejected). That is a new planner event. Not done here.
  - Host-side `files` events (`forward`, `mount`, `unmount`, and now `eject`) are not listed in `docs/LOGGING.md`. That file is the orchestrator's, and not in `files:`.
