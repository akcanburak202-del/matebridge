---
id: T-209
title: Force-unmount a stale tablet files volume when its token is dead, then remount
status: done
phase: 6
owner: mac-host-dev
depends_on: [T-206]
decisions: [0015, 0028]
files:
  - host-mac/Sources/MateBridgeCore/Files/TabletFilesPlanner.swift
  - host-mac/Sources/MateBridgeHost/Files/TabletFilesBridge.swift
  - host-mac/Tests/MateBridgeCoreTests/Files/TabletFilesPlannerTests.swift
  - docs/LOGGING.md
  - backlog/tasks/T-209-host-force-unmount-stale-volume.md
---

## Amaç

Cihaz 2026-10-04 ~01:10: tablet uygulaması birkaç kez yeniden başlatıldı (her başlangıç yeni WebDAV token'ı demek). Mac eski "MatePad" birimini çıkarmaya çalıştı ama birim meşguldü (Finder'da açıktı): `ev=unmount result=error code=16` (EBUSY). Ölü birim `/Volumes/MatePad`'de kaldı (`ls`: Permission denied), sonraki bağlamalar `ev=mount result=error code=17` (EEXIST) ile başarısız oldu. Kullanıcı: "Tablet dosyalarını aç" → "bağlanamadı"; Finder'da MatePad'e girince "öğesinin özgünü bulunamadı". `diskutil unmount force /Volumes/MatePad` ile düzeldi.

## Bağlam

- Token değişince eski birimdeki kimlik bilgisi geçersizdir; birimde yazılmayı bekleyen veri sunucuya zaten ulaşamaz. Bu yüzden **ölü token'lı** birimi zorla çıkarmak veri kaybı yaratmaz (tablet tarafı açısından); normal (geçerli token'lı) kullanıcı birimine zorla çıkarma uygulanmaz.
- T-206 eject mantığı: kendi başlattığımız çıkarma kullanıcı "Çıkar"ı sayılmamalı; zorla çıkarma da kendi çıkarmamızdır.
- EEXIST'te: bağlama noktası bizim ölü birimimizse (yol, bilinen önceki bağlama yolumuz ve mount listesinde `http://127.0.0.1:<eski port>/MatePad/`), önce zorla çıkar, sonra bağla. Başka bir şeyse (kullanıcının kendi "MatePad"i) dokunma, hata göster.
- Zorla çıkarma `diskutil unmount force` ya da `unmount(2)` `MNT_FORCE`; arayüz açmaz.

## Kapsam dışı

- Tablet tarafı, protokol.

## Kabul kriterleri

- [x] [XCTest] Token değişti + çıkarma EBUSY → bir kez zorla çıkarma → başarılıysa yeni token ile bağlama (yeniden bağlama niyeti varsa) ya da kullanıcı açtığında bağlama başarılı. _(`tokenChangeWithABusyVolumeForcesItOnceThenRemounts`, `busyVolumeLeftAtSessionEndIsForcedOnceTheNextSessionHasANewToken`, `remountAfterOffWaitsForThePendingForce`)_
- [x] [XCTest] Bağlama EEXIST ve yol bizim ölü birimimiz → zorla çıkar + bir kez yeniden dene; yol bizim değilse zorla çıkarma yok, hata görünür. _(`mountCollidingWithADeadLeftoverForcesItAndRetriesOnce`, `collisionRetryIsTriedOnlyOnce`, `collisionWithAVolumeThatIsNotOursForcesNothing`)_
- [x] [XCTest] Geçerli token'lı birimde zorla çıkarma asla yok (oturum sonu teardown'da EBUSY → normal yeniden deneme, bugünkü gibi). _(`liveTokenVolumeIsNeverForced`)_
- [x] [XCTest] Zorla çıkarma kullanıcı "Çıkar"ı (T-206 eject) sayılmaz. _(`forcedUnmountIsNotAnEject`)_
- [ ] [device] MatePad Finder'da açıkken tablet uygulamasını yeniden başlat (force-stop + start): birim birkaç saniyede yeni token ile geri gelir; "Tablet dosyalarını aç" çalışır; `ev=unmount … force=1` bir kez.

## Plan

Karar mantığı `TabletFilesPlanner`'da (saf, test edilir); köprü yalnız yürütür ve sonucu bildirir.

1. **Token takibi:** bağlanan birimin token'ı (`FilesSecret`, yalnız bellekte) `mountedPath` ile birlikte tutulur; `ReplacedMount` da token taşır.
2. **Oturum sınırını aşan sonuç:** bugün `sessionEnded`/`sessionStarted` `replacedMounts`'u siler, ama teardown'ın `unmount` sonucu ondan sonra gelir. Artık oturum sınırında silinmez, `inSession=false` işaretlenir: eject çıkarımı, izlenen yol ve yeniden bağlama kapısı yalnız `inSession` olanlara bakar (T-206 davranışı aynı). Kapanışta silinir.
3. **Artık birim (leftover):** `unmountFinished`'ta `stillMounted` içinde olan değiştirilmiş birim (EBUSY) `leftovers`'a geçer (yol, port, token; en çok 4, oturumlar arası, kapanışta silinir). Aynı porttaki sonraki `unmount` sonucunda `detached` ya da hiç bulunmayan artık silinir; bizim yeni bağlamamız aynı yola düşerse de silinir.
4. **Ölü = token farklı:** bir artık, bilinen READY token'ı onun token'ından farklıysa ölüdür. READY yoksa (OFF, oturum yok) bilinmez → zorla çıkarma yok. Aynı token → canlı → asla zorla çıkarma.
5. **Hemen zorla çıkarma (bir kez):** ölü ve henüz denenmemiş artık için `forceUnmount(path:localPort:)` aksiyonu; `unmountFinished` (aynı oturumda token değişimi + EBUSY) ve yeni READY (oturumlar arası, cihazdaki durum) anında. Yeniden bağlama (`autoMountIfArmed`) bekleyen zorla çıkarma sonuçlarını bekler. Sonuç: `forceUnmountFinished(path:localPort:gone:)`.
6. **EEXIST:** köprü NetFS `status == EEXIST`'te `mountCollided(generation:localPort:mountedNow:)` çağırır (`mountedNow`: o porttaki bizim WebDAV birimlerimiz). `mountedNow` içinde ölü artığımız varsa → zorla çıkar + başarılıysa bir kez yeniden bağla (yeniden deneme de EEXIST alırsa hata görünür, döngü yok). Yoksa (kullanıcının kendi "MatePad"i, canlı token'lı birim, bilinmeyen) → zorla çıkarma yok, `lastMountFailed`.
7. **Eject sayılmaz:** artıklar `watchedPaths`'te yok; zorla çıkarma bildirimi `volumeUnmounted`'da eject sayılmaz.
8. **Köprü:** `forceUnmount` yalnız yol hâlâ `127.0.0.1:<port>` WebDAV birimiyse `unmount(2)` `MNT_FORCE`; log `ev=unmount result=ok|error|gone force=1`, EEXIST kararı `ev=mount_exists dead_ours=N`. Yol/token loglanmaz.
9. **Testler** (`TabletFilesPlannerTests.swift`): dört XCTest kriteri + sınır durumları. T-206 testi `busyOldVolumeIsOursAndItsLaterUnmountIsNotAnEject` yeni davranışa (önce zorla çıkarma) göre güncellenir; iddiaları korunur.
10. `docs/LOGGING.md`: T-209 bölümü.

## Handoff

- **Commit:** second Codex fix `745ea8a`, first Codex fixes `ec3a9fd`, implementation `b16e45c`, plan `41dd96b`; the handoff commits follow. Branch `task/T-209-host-force-unmount-stale-volume`. `./scripts/check.sh` ALL OK (host: 804 tests).
- **Codex review, second pass (--high), one P2, fixed in `745ea8a`: reuse adopted a replacement volume.**
  - The reuse decision moved into the planner: `mountReused(generation:localPort:path:identity:) -> [TabletFilesAction]?`. The bridge calls it when `mount` finds a volume of ours at `knownPath`.
  - It is adopted only if it is the current request's `mountedPath` and, when we hold an identity for it, exactly that identity. A reuse keeps the identity we recorded and never records a new one. An identity is recorded only at the completion of a mount we made ourselves.
  - A mismatch returns nil: our record of the path is forgotten (`mountedPath` and origin cleared), and the bridge logs `ev=mount already=0 reason=identity` and mounts afresh. The fresh mount may land elsewhere, or collide (EEXIST) and fail visibly, never forced.
  - A stale request reuses and mounts nothing.
  - Tests: `reopeningAReplacedVolumeNeverAdoptsItAndNeverForcesIt` (replacement → reopen → token change: no force of the replacement), `reopeningOurOwnVolumeKeepsTheIdentityWeRecorded`.
- **Codex review (--high), two findings, both fixed in `ec3a9fd`:**
  - **P1, a replacement volume could be forced.** Each mount now records the volume's identity right after it succeeds: `VolumeIdentity`, read from `getfsstat`, with `f_fsid` (assigned per mount), `f_fstypename` and the exact `f_mntfromname`. The identity travels with the replaced volume and the leftover, and goes in the action `forceUnmount(path:localPort:identity:)`.
    - Right before `MNT_FORCE`, the bridge re-reads the entry at that path and calls the pure Core check `TabletFilesPlanner.identityMatches(expected:current:localPort:)`. It requires an equal identity, type `webdav`, and exactly `http://127.0.0.1:<port>/MatePad/`: no user, query or other path.
    - On a mismatch there is no force, `ev=unmount result=skipped reason=identity force=1` is logged, and the result is reported as gone, so the leftover is forgotten.
    - A leftover with no recorded identity is never forced.
    - Tests: `identityMatchesOnlyTheExactVolumeWeMounted`, `leftoverWithoutAKnownIdentityIsNeverForced`.
  - **P2, the remount could run before a queued unmount.**
    - Forces now come after the normal cleanup in the same list (`[unmount, forceUnmount]`, `teardown + forces + installForward`).
    - The planner counts `unmount(localPort:)` actions until their results come back (`pendingUnmounts`). The automatic remount and the collision retry wait until every queued unmount and force has reported (`resumeAfterCleanup`).
    - One exception keeps T-206's action lists: the mount may follow, in the same list, the unmount the same step just emitted, because the host reports that unmount before it runs the next action.
    - Test: `remountWaitsForTheWholeCleanupAfterAUsbReturn` checks the exact list `[unmount(47010), forceUnmount(...)]` and both result orders.
  - T-206 tests are unchanged and green. In the T-209 tests, `mounted()` now passes an identity.
- **Dokunulan dosyalar:** `host-mac/Sources/MateBridgeCore/Files/TabletFilesPlanner.swift`, `host-mac/Sources/MateBridgeHost/Files/TabletFilesBridge.swift`, `host-mac/Tests/MateBridgeCoreTests/Files/TabletFilesPlannerTests.swift`, `docs/LOGGING.md`, this card.
- **Davranış (planner):**
  - New action `forceUnmount(path:localPort:)`; new events `forceUnmountFinished(path:localPort:gone:)` and `mountCollided(generation:localPort:mountedNow:)`; new state `leftoverPaths`.
  - The token a volume was mounted with is kept (in memory, `FilesSecret`) with `mountedPath` and each replaced volume.
  - `replacedMounts` are no longer dropped at session start/end: they are marked `inSession=false`, so the teardown's unmount result (which arrives after the boundary) is still seen. Eject inference, `watchedPaths` and the remount gate use only `inSession` ones, so T-206 behaves as before.
  - A replaced volume reported in `stillMounted` becomes a leftover (at most 4, across sessions, cleared at shutdown). Dropped when a later unmount on its port detaches it or does not find it, or when our new mount lands on its path.
  - Dead = mounted with a token other than the current READY's. No READY (OFF, no session) → not provably dead. The current `mountedPath` is never dead.
  - Each dead leftover gets one automatic force, as soon as it is known dead: in `unmountFinished` (same-session token change) or in `filesInfo` (the next READY, e.g. the next session in the device case). An owed remount waits for pending force results.
  - EEXIST: if a dead leftover of ours is among `mountedNow` → force it (again, even if the automatic force failed) and, if every force succeeded, retry the mount once (same automatic/user flag). The retry that hits EEXIST again, a failed force, or a volume that is not a dead leftover of ours → no force, `lastMountFailed`. While the force/retry is pending the menu shows `mounting`.
  - Leftovers are not in `watchedPaths`, so a forced unmount's notification never reaches `volumeUnmounted`. Even if it did, it is not `mountedPath`, so it is not an eject.
- **Davranış (bridge):**
  - `forceUnmount`: only if the path is still a WebDAV volume from `127.0.0.1:<port>` (`getfsstat`), `Darwin.unmount(path, MNT_FORCE)`; reports `gone` (detached or absent).
  - NetFS callback `status == EEXIST` → `mountCollided` with `mountPoints(localPort:)`, instead of `mountFinished`.
  - Logs: `ev=unmount result=ok|gone|error code=N force=1`, `ev=mount_exists dead_ours=N`. No path or token.
- **Varsayımlar:**
  - A tablet server start always gets a new token, so a different token means the old server and the old volume's credentials are gone.
  - NetFS answers EEXIST in its callback when the same URL is already mounted (device log `ev=mount result=error code=17` matches the callback's format).
  - `unmount(2)` with `MNT_FORCE` works for the user's own NetFS WebDAV volume without root, like the plain `unmount` already used, and does not hang on a dead server.
  - `f_fsid` of a WebDAV volume is unique per mount while the system runs, so a later volume at the same path gets another one.
  - A small window remains between the identity check and `unmount(2)`, which takes a path. Another mount would have to land at that exact path within microseconds.
  - Memory only: if the Mac app restarts, it does not know earlier volumes, so it forces nothing (EEXIST stays visible, as today).
- **Test edilmeyenler / cihazda doğrulananlar:** nothing was run on hardware (no app launch, no mount, no unmount). Device checks:
  - **[device] criterion (cross-session):** mount "MatePad", keep it open in Finder, force-stop and restart the tablet app. Expect `ev=unmount result=error code=16` at session end, then `ev=unmount result=ok force=1` once when the new session's READY arrives, then "Tablet dosyalarını aç" mounts with no EEXIST. See the first open question about the volume "coming back by itself".
  - **Same session:** with "MatePad" open in Finder, change the shared folder on the tablet (token change without a session change). Expect `code=16`, then `force=1` once, then the volume comes back by itself (T-206 remount), with no Finder window.
  - **No force on a live volume:** with "MatePad" open in Finder, unplug and replug USB (same server, same token). There must be no `force=1`.
  - **User's own volume:** not practical to set up; covered by tests only.
  - Check what Finder does with a window open on a force-unmounted volume (it should close or show the volume as gone, with no dialog).
  - Check that `MNT_FORCE` returns quickly on a dead WebDAV volume.
  - Check that the fsid read right after the mount is the same one `getfsstat` shows later for that volume, so no `result=skipped reason=identity` appears in the device case above.
- **Açık sorular:**
  - **Device criterion vs. T-206 scope:** "birim birkaç saniyede yeni token ile geri gelir" after force-stop + start. A force-stop ends the session, and T-206 deliberately clears the remount intent at session end ("a new session still needs the user's 'Tablet dosyalarını aç'", test `sessionEndAndShutdownForgetTheIntent`). So after an app restart the dead volume is forced away within seconds, but it comes back only when the user opens it. That open now works. If the volume should come back by itself across sessions, that needs a new card, because it changes the T-206 intent rule.
  - **Live-token leftover blocks a mount:** USB loss with a busy volume, then USB back with the same server. The volume is alive again, but a user "open" gets EEXIST and fails (it is not adopted). This is the same as before T-209, and it is not forced, as the card requires. Adopting it (passing it as `knownPath`) would fix it, but that is outside this card.
