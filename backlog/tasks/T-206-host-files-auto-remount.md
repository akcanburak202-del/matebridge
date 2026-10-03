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

5. Eject wiring: the bridge observes `NSWorkspace.didUnmountNotification` and hands it to `planner.volumeUnmounted(path:mountedNow:)`. It removes the observer at shutdown and in `deinit`.
6. Codex review (2 × P2):
   - **Eject handled after a restart:** a restart forgets the volume, keeps it as a replaced volume (at most `rememberedMounts` = 4, cleared per session), and emits `unmount`. The bridge reports what that unmount found through `unmountFinished(localPort:detached:stillMounted:)`. A replaced volume that was already gone counts as the user's eject, and the remount waits for this report.
   - **Notification flood:** the bridge filters on the posting thread against a snapshot of `planner.watchedPaths`, keeps a bounded queue, and has at most one drain block pending.

## Handoff

- **Commit:** final `0e6138a`. History: plan `093aa00`, remount `6827ec1`, eject wiring `15f5a4a`, Codex fixes `ffc7145` and `0e6138a`. Branch `task/T-206-host-files-auto-remount`. `./scripts/check.sh` ALL OK (host: 788 tests).
- **Dokunulan dosyalar:** `host-mac/Sources/MateBridgeCore/Files/TabletFilesPlanner.swift`, `host-mac/Tests/MateBridgeCoreTests/Files/TabletFilesPlannerTests.swift`, `host-mac/Sources/MateBridgeHost/Files/TabletFilesBridge.swift` (orchestrator-approved), this card.
- **Davranış (planner):**
  - State:
    - `keepsMounted`: the user's intent.
    - `autoMountArmed`: one attempt owed for the current READY.
    - `mountingIsAutomatic`.
    - `replacedMounts`: volumes we asked to unmount whose result is not in yet. Bounded at 4, cleared by session start/end and shutdown.
  - Public API: `unmountFinished(localPort:detached:stillMounted:)`, `volumeUnmounted(path:mountedNow:) -> Bool`, `watchedPaths`, `remountsAfterRestart`, `normalizedPath`, `rememberedMounts`.
  - **Same port + new token:**
    - With a mounted volume, `filesInfo` returns `[cancelMount?, unmount]`. The remount comes from `unmountFinished`, once the result shows the volume was still ours (detached or busy).
    - With no volume (e.g. the user's mount still in flight), the remount follows the unmount in the same list.
  - **OFF → READY / port change:** the remount comes from `forwardFinished` or `unmountFinished`, whichever comes last.
  - **Eject, two paths:**
    1. *Notification first:* the current `mountedPath` is no longer in `mountedNow` → eject. The decision rests on the current volume being gone, not on which notification arrived. So a late, duplicated or lost notification of our own earlier unmount cannot hide a later eject.
    2. *Restart first:* our `unmount` does not find the replaced volume (in neither `detached` nor `stillMounted`) → eject. The late notification of that path is then ignored.
  - **Our own unmounts never count:**
    - The path is forgotten before `unmount`.
    - The result marks it as ours, whether detached or busy (busy meaning the unmount failed and the old volume stayed).
    - A remount on the same mount point is in `mountedNow`.
  - **Tests (Codex cases and others):**
    - `ejectSeenOnlyAfterATokenChangeStillPreventsTheRemount`
    - `ejectSeenOnlyAfterOffStillPreventsTheRemount`
    - `ourOwnUnmountWithALateNotificationStillRemounts`
    - `busyOldVolumeIsOursAndItsLaterUnmountIsNotAnEject`
    - `remountWaitsForTheUnmountResultWhicheverComesFirst`
    - `replacedVolumesAreBoundedAndForgottenPerSession`
    - `unmountResultOfAnotherPortResolvesNothing`
  - An automatic mount does not emit `.reveal`. A failed one sets `lastMountFailed` and waits for the next READY or the user.
  - The existing test `mountWithAnOldTokenIsDetachedWhenItFinishes` now expects the remount; the stale-detach part is unchanged.
- **Davranış (bridge):**
  - The observer filters on the posting thread: the path is normalized, then matched against the `watchedPaths` snapshot (refreshed under the lock after every `apply`). Unrelated volumes queue nothing.
  - Watched paths are queued in order, duplicates kept, at most 16. Only one drain block is pending, and it computes `mountPoints` once per drain.
  - `.unmount` now reports `unmountFinished` with the paths it detached or failed to detach, before any other action runs.
  - Log: `ev=eject remount=off seen=notification|unmount`. No path or token is logged.
- **Varsayımlar:**
  - The intent starts with `openRequested`.
  - USB device loss within the session keeps the intent.
  - A transport change away from USB is always a new session.
  - `Darwin.unmount` is synchronous, and every `unmountFinished` is applied on the bridge queue before the next queued block. So when a notification is handled, the results of all earlier unmounts are already known.
- **Test edilmeyenler / cihazda doğrulananlar:** nothing was run on hardware (no app launch, no mount). Device checks:
  - **[device] criterion:** mount "MatePad", change the shared folder, then toggle read-only. The volume comes back by itself within a few seconds, with no Finder window.
  - **Eject:** mount "MatePad", eject it in Finder, then change the shared folder. There must be **no** remount, and `ev=eject remount=off` appears once.
  - **Repeated remount:** with the volume mounted, change the scope twice. It comes back both times, so our own unmount was not taken as an eject.
  - **Busy volume:** with a file open on the volume, change the scope. Check whether the remount lands on `MatePad-1` and what Finder shows.
  - **Auto-disconnect risk:** if macOS webdavfs unmounts the volume by itself when the tablet server stops, before `FILES_INFO` OFF is processed, our unmount finds nothing. That is taken as the user's eject (`seen=unmount`), so there is no remount. If the device test shows `seen=unmount` without a user eject, this needs revisiting.
  - Check that `NSWorkspace.didUnmountNotification` arrives for a NetFS WebDAV volume in a windowless menu-bar app, with `volumeURLUserInfoKey`.
- **Açık sorular:**
  - Host-side `files` events (`forward`, `mount`, `unmount`, `eject`) are not in `docs/LOGGING.md`, which is not in `files:`.
  - Only a microscopic race remains: the user's eject and our unmount hitting the same volume at the same moment. It is not handled.
