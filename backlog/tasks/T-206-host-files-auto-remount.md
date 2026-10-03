---
id: T-206
title: Remount the tablet files volume after a server restart if it was mounted
status: todo
phase: 6
owner: mac-host-dev
depends_on: [T-190]
decisions: [0028]
files:
  - host-mac/Sources/MateBridgeCore/Files/TabletFilesPlanner.swift
  - host-mac/Tests/MateBridgeCoreTests/Files/TabletFilesPlannerTests.swift
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

- [ ] [XCTest] Mounted → `FILES_INFO` with same port and new token → unmount, then exactly one `.mount` with the new token once the forward is up (no user action).
- [ ] [XCTest] Mounted → OFF → READY (new token, possibly new port) in the same session → one `.mount` after the new forward is installed.
- [ ] [XCTest] Never mounted (user never opened) → restart → no `.mount`.
- [ ] [XCTest] User ejected / unmounted → restart → no `.mount`. `sessionEnded` or shutdown clears the intent; a later session needs `openRequested`.
- [ ] [XCTest] A failed automatic remount does not loop: at most one automatic attempt per READY.
- [ ] [device] Mount "MatePad" in Finder, change the shared folder on the tablet (and toggle read-only): the volume comes back by itself within a few seconds with the new scope; no menu action needed.

## Plan

_(Ajan kodlamadan önce doldurur.)_

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulananlar:**
- **Açık sorular:**
