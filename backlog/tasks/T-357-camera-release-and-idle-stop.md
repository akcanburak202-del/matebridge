---
id: T-357
title: Kamera — "Kamerayı şimdi kapat" (release_seq) ve boşta kullanım denetimi (karar 0040 ek 2, politika C)
status: review
phase: 7
owner: mac-host-dev + android-client-dev
depends_on: [T-354, T-355]
decisions: [0040]
files:
  - host-mac/Sources/
  - host-mac/Tests/
  - client-android/app/src/main/
  - client-android/app/src/test/
  - docs/KNOBS.md
  - docs/LOGGING.md
  - backlog/tasks/T-357-camera-release-and-idle-stop.md
---

## Amaç

Karar 0040 ek 2 ve PROTOCOL.md (dal `task/T-356-camera-integration`, commit 2e417246): `CAMERA_PREFS.reserved` → `release_seq`; kullanım bitişi politikası C. Fixture `camera_prefs_auto` değişti (release_seq = 2).

## Host

1. Kodek: `CAMERA_PREFS.release_seq` (fixture testleri).
2. `release_seq` değişimi: START durumundaysa STOP + **bırakılmış** durum. Bırakılmışken START yok; host yazmıyorken kullanım 0 görülüp sonra yeniden 1 olunca bırakılmış durum kalkar ve normal kural işler. `mode` OFF'a geçiş de temizler. Oturum başında `release_seq` taban değeri ilk gelen değerdir (değişim sayılmaz).
3. **Periyodik denetimi kaldır** (T-354'ün 15 sn'lik `MATEBRIDGE_CAMERA_PROBE_S` yolu). Yerine: yazarken yalnız (a) Mac'te kullanıcı girdisi 10 dk yokken (`CGEventSourceSecondsSinceLastEventType`, combinedSession, any input) ve boşta kaldıkça her 10 dk'da bir, (b) Mac uykuya ya da ekran uykusuna giderken (`NSWorkspace` willSleep / screensDidSleep) kısa denetim (sink'i durdur, kullanımı oku, kullanım varsa yazıma dön). Kullanım yoksa STOP. Denetim aralığı ve boşta eşiği için knob (`MATEBRIDGE_CAMERA_IDLE_S`, varsayılan 600) KNOBS.md'de; eski knob silinir.
4. Durdurma süresini ölç ve kısalt: özelliğin düşmesi için gereken en kısa bekleme (T-354 0,6 sn kullandı; dinleyiciyle erken çık).
5. Mac menüsündeki "kullanımda say (elle)" öğesi kalabilir; davranışı: açıkken boşta denetim de yapılmaz.
6. Testler: release_seq tablosu (START'ta değişim → STOP + bırakılmış; bırakılmışken kullanım 1 kalırsa START yok; 1→0→1 sonrası START; OFF temizler; ilk değer değişim değil), boşta denetim zamanlaması (sahte saat, sahte girdi yaşı), uyku olayı.

## İstemci

1. Kodek: `CAMERA_PREFS.release_seq` (fixture testleri).
2. Panel: Kamera bölümünde, kamera **akarken** (START + bağlantı kurulu) görünen bir eylem: "Kamerayı şimdi kapat". Basınca `release_seq` +1 (oturum içinde sayaç; oturum başında 0) ve hemen `CAMERA_PREFS` gönder. Mevcut öğe türleriyle (Action, `hidden`); T-352 görünüm kodu Action'ları en alta topluyor: bu eylem kamera bölümünde kalmalı (gerekirse `SettingsViews`'te Action'ı yerinde bırakan küçük bir bayrak, ör. `inline = true`; diğer eylemlerin yeri değişmez).
3. Testler: sayaç ve gönderim, görünürlük.

## Kabul

- `./scripts/check.sh` tam olarak geçer.
- Cihaz testi orkestratörde.

## Plan

## Handoff

## Handoff (client)

- Commits: 60669dc4 (release_seq + eylem), d94269d0 (CameraStreamer startup/close serialization, Codex P2). Son: d94269d0.
- Dosyalar: protocol Messages/Codec (CameraPrefs.releaseSeq u16), camera/CameraWish.kt (CameraReleaseCounter, Policy.wire releaseSeq), settings/SettingsCatalog+SettingsViews (Action.inline/hidden, `camera_release`), MainActivity (sayac, releaseCameraNow, cameraStreaming = uiState ACTIVE), CameraStreamer (startLock + closed kontrolu; close() pipeline/scheduler'i startLock altinda durdurur), testler.
- Varsayim: sayac uygulama calismasi boyunca artar (oturum basinda 0'a donmez): SessionMachine son CAMERA_PREFS'i oturumlar arasi hatirliyor, sifirlama host taban degeriyle cakisabilirdi; host ilk degeri taban sayar, bu yeterli. u16 sarar.
- Eylem yalniz inStream && kamera ACTIVE && uzak oturum degil iken gorunur; panel yenilenmesi mevcut refresh/onChanged ile (durum degisince otomatik yenilenmiyorsa panel yeniden acilinca gorunur).
- check.sh --only android: OK.
- Tablette bak: kamera akarken Kamera bolumunde "Kamerayi simdi kapat" gorunuyor mu (bolumde, altta degil); basinca Mac kamerayi kapatiyor ve uygulama kullanmaya devam etse de yeniden acmiyor mu; kamera akmazken eylem gizli mi.

## Open questions

## Handoff (host)

- Commits: fb69ab67 (release_seq, idle/sleep audit, tests, KNOBS/LOGGING), then the Codex P2 commit (see git log, branch task/T-357-host).
- Files: CameraMessages.swift (releaseSeq codec), CameraController.swift (released state), CameraUsageTracker.swift (periodic probe removed, startProbe, early exit when the property falls, settle 0.5 s), new CameraIdleAudit.swift, CameraKnobs.swift (MATEBRIDGE_CAMERA_IDLE_S=600, probe knob removed), CameraBridge.swift (idle timer via CGEventSource, NSWorkspace willSleep/screensDidSleep observers only while the camera is watched), tests, docs/KNOBS.md row 49, docs/LOGGING.md.
- Probe pause: 0.5 s maximum (was 0.6), ends at once when the raw property falls. NOT measured on hardware; a too-short value only causes a harmless resume and a retry 10 min later.
- Codex P2 fixes: (1) ObsVirtualCamera.write stages one frame, newest wins, drops counted as queue_full; (2) CameraConnectionService .close of the active connection now voids work like socketClosed (shared voidActiveWork); (3) one pending CODEC_CONFIG, latest wins, skipped if the connection generation changed (own connection generation, not the gate epoch, so an overflow does not discard a still valid config); (4) startedStream keeps the started IDs, stop always clears local sink state. No unit tests for 1-4 (CMIO/VT glue); --camera-selftest passes.
- Not tested on hardware: sleep observers, CGEventSource idle age, real OBS probe timing.

### Round 2 (Codex, branch task/T-357-host-r2)

- P2-1: new Core `CameraDecodeStore` (max 2 frames, one config, one drain closure on the decode queue) replaces one closure per frame; overflow/decode error drop waiting frames, a config replaces waiting frames. `CameraStreamGate.codecConfig()` now advances the epoch (frames queued before a config are void).
- P2-2: generation checked again right before the sink in `decoded`; `ObsVirtualCamera.writesEnabled` is false until `enableWrites()` (listener opened, or a camera connection became active) and false again after `stopSink()`.
- P2-3: every store item carries its decoder and the connection generation; the drain no longer captures a decoder.
- Boundary test: CamFrame.maxDataBytes == 4194284, max sealed ok, max+1 rejected. Tests: CameraDecodeStoreTests, gate tests. Full check.sh ALL OK, --camera-selftest passes. Single commit for all three (they share code).
