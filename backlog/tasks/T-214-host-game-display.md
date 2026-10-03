---
id: T-214
title: Host: 1x game display at the requested pixel size (decision 0029)
status: review
phase: 6
owner: mac-host-dev
depends_on: [T-213]
decisions: [0029]
files:
  - host-mac/Sources/MateBridgeCore/Video/VideoSettings.swift
  - host-mac/Sources/MateBridgeCore/Video/StreamSettings.swift
  - host-mac/Sources/MateBridgeCore/Video/StreamPrefsPolicy.swift
  - host-mac/Sources/MateBridgeCore/Video/GameDisplayPolicy.swift
  - host-mac/Sources/MateBridgeCore/Video/StreamPrefsStore.swift
  - host-mac/Sources/MateBridgeCore/Video/DisplayLease.swift
  - host-mac/Sources/MateBridgeCore/Video/EncoderKnobs.swift
  - host-mac/Sources/MateBridgeHost/VirtualDisplay.swift
  - host-mac/Sources/MateBridgeHost/Video/VideoPipeline.swift
  - host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift
  - host-mac/Sources/MateBridgeHost/Session/UserDefaultsStreamPrefsStore.swift
  - host-mac/Tests/MateBridgeCoreTests/Video/
  - docs/LOGGING.md
  - backlog/tasks/T-214-host-game-display.md
---

## Amaç

Karar 0029: `STREAM_PREFS.display_*` geçerliyse host sanal ekranı HiDPI olmadan (1x) o piksel boyutunda kurar; oyun modundan çıkınca 2800×1840 HiDPI'ya döner. PROTOCOL §0x05 host kuralları (T-213) sözleşmedir.

## Bağlam (tasarım, 2026-10-04)

- `VideoSettings`: `displayHiDPI` (varsayılan true) + değişmeyen `nativeWidthPx/HeightPx` (HELLO'dan, `StreamSettings`); `widthPx/heightPx/widthPt/heightPt` = kurulan ekran; `sameDisplay` HiDPI'yı da karşılaştırır; `sameNative(as:)`; `displayModeText` (ör. `1848x1214@1x`).
- `StreamPrefsPolicy.applying`: geçerli ekran → `widthPx=widthPt=w`, `heightPx=heightPt=h`, `displayHiDPI=false`, `scalePermille=1000`; aksi hâlde doğal + prefs ölçeği. Geçerlilik saf `GameDisplayPolicy.accepts(w:h:nativeW:nativeH:)` (çift, [doğal/2, doğal], en-boy ±%0,5). Varsayılan bit hızı etkin ölçekle (`1000·encodedWidth/nativeWidth`).
- `DisplayLease`: kimlik = cihaz + doğal boyut; kip farkı `.reconfigure` (sahip `obtainDisplay` ile yeniden kurar), `.sizeChanged` teardown yalnız HELLO boyutu farklıysa. **Bugünkü `teardown+create` yolu 700 ms beklemesini atlıyor** (aynı seri numarasıyla kurulum başarısız olabilir) — kip değişimi bu yoldan gitmemeli.
- `VideoPipeline.obtainDisplay`: devralınan ekran yalnız piksel boyutu + HiDPI + yenileme + çevrimiçi eşleşirse yeniden kullanılır; aksi hâlde kaldır, 700 ms bekle, `hidpi: settings.displayHiDPI` ile kur (bugün `true` sabit). 1x'te `modeSelected == false` → `gameDisplayUnavailable`.
- `VirtualDisplay.swift` (tek CGVirtualDisplay dosyası): `pixelWidth/Height/hidpi` saklanır; `physicalPixelWidth/Height` parametresi (varsayılan = piksel) — `sizeInMillimeters` fiziksel panel (2800 px / 264 dpi) kalır. 1x dalı zaten var.
- `StreamCoordinator`: `display_recreate reason=mode_change mode=A->B`, `onStreamPrefs` `display=`/`requested_display=`, `applyPrefs` `display=old->new`, `display_parked` kip; `streamConfig(for:)` doğal boyutu HELLO ile karşılaştırır. **Geri düşüş:** 1x kurulamazsa süreç için `gameDisplayFailed`, `game_display_failed applied=…`, tercih ekran yok sayılarak yeniden uygulanır (yeni `config_id`), tek deneme.
- `StreamPrefsStore`: `[fps, scale, bitrate, dw, dh]`; 2/3/5 değerli kayıtlar okunur. `EncoderKnobs` `ev=profile display=`.
- Girdi eşlemesi değişmez: `VirtualDisplayLocator` ekran sınırlarını ve ölçeği her seferinde okuyor; 1x'te ölçek 1.

## Kabul kriterleri

- [x] [XCTest] Geçerli boyut → 1x 1848×1214, STREAM_CONFIG px = pt = 1848×1214, ölçek yok sayılır; geçersiz (tek sayı, doğaldan büyük, yarıdan küçük, en-boy > %0,5, bir boyut 0) → doğal HiDPI; `display=0` → bugünküyle aynı STREAM_CONFIG.
- [x] [XCTest] Varsayılan bit hızı 1848 için 660 değeriyle aynı; 5'li kayıt gidip gelir, 2/3'lü eski kayıtlar okunur.
- [x] [XCTest] Lease: aynı cihaz + doğal boyut, farklı kip → `.reconfigure` (aktif ve bekletilmiş); farklı doğal boyut → teardown+create. `obtainDisplay` yalnız tam eşleşmede yeniden kullanır (saf karar fonksiyonu Core'da).
- [x] [XCTest] 1x hatasında tek doğal geri düşüş.
- [x] [doc] LOGGING yeni alanlar. `VirtualDisplay` tek CGVirtualDisplay dosyası. `./scripts/check.sh` yeşil.
- [ ] [device] T-216.

## Plan

1. Core `VideoSettings`: `replacedNative` (1x oyun ekranının yerine geçtiği doğal HiDPI boyutu; nil = doğal ekran) → `displayHiDPI`, `nativeWidthPx/HeightPx` (HiDPI'da ekranın kendisi; böylece mevcut testlerdeki "widthPx değişti" doğal boyut değişimi sayılır), `sameDisplay` HiDPI'yı da karşılaştırır, `sameNative(as:)`, `displayModeText`, `displayMode`.
2. `GameDisplayPolicy.swift` (yeni): `accepts(w:h:nativeW:nativeH:)`; `DisplayMode` + `DisplayReuse.decide` (yalnız piksel+HiDPI+yenileme+çevrimiçi eşleşirse yeniden kullan; neden mode_change/refresh_change/offline); `DisplayRecreateGap` (son kaldırmadan 700 ms); `GameDisplayFallback` (1x hata → tek doğal geri düşüş, süreç boyunca oyun ekranı kapalı).
3. `applying(_:defaultRefreshHz:allowGameDisplay:)`: geçerli ekran → 1x w×h, pt = px, ölçek 1000; aksi hâlde doğal + prefs ölçeği; varsayılan bit hızı etkin ölçekle. `initialSettings` aynı bayrağı geçirir.
4. `DisplayLease`: kimlik = cihaz + doğal boyut; kip/yenileme farkı `.reconfigure`.
5. `StreamPrefsStorageCodec`: ekran 0×0 ise 3, değilse 5 değer yazar; 2/3/5 okur. `StreamProfileLog` `display=`.
6. Host: `VirtualDisplay` piksel/HiDPI/yenileme saklar, `physicalPixelWidth/Height`, kaldırma zamanını kaydeder; `VideoPipeline.obtainDisplay` Core kararını kullanır, her yeni ekrandan önce kaldırma boşluğunu (700 ms) bekler, `hidpi: settings.displayHiDPI`; 1x'te `modeSelected == false` → `gameDisplayUnavailable`.
7. `StreamCoordinator`: loglar (`display_recreate reason=mode_change mode=A->B`, `stream_prefs display=/requested_display=`, `stream_reconfigure display=`, `display_parked mode=`), `streamConfig(for:)` doğal boyutu karşılaştırır, `createPipeline` hata → `game_display_failed` geri düşüşü (yeni `config_id`).
8. Testler (Core), LOGGING.md, `./scripts/check.sh`.

## Handoff

- **Commit:** `f181c3f` (uygulama; plan `ece954d`), `577fca9` (Codex P2 düzeltmesi, aşağıda); Handoff ayrı commit. `./scripts/check.sh` ALL OK (XCTest 437, `GameDisplayTests` 22 test; Swift Testing 805).
- **Codex P2 (HELLO ↔ etkinleştirme uyuşmazlığı) düzeltmesi:** `SessionMachine` HELLO'da hesaplanan `STREAM_CONFIG`'i gönderiyor, koordinatör ayarı etkinleştirmede (kanıttan sonra) yeniden türetiyor; arada `game_display_failed` olursa tablet oyun config'iyle kalıp aynı `config_id` altında doğal hat çalışıyordu. `SessionMachine`/`SessionServer`/`main.swift` kart kapsamı dışında olduğundan düzeltme koordinatörde: `streamConfig(for:)` cihaz başına gönderilen config'i Core `AnnouncedStreamConfigs`'e kaydeder (en çok 16 cihaz); `sessionStarted` etkinleştirme ayarının config'ini onunla karşılaştırır (kayıt tüketilir). `config_id` ve `bitrate_kbps` dışında fark varsa (bit hızı bugün de farklı olabiliyor: Wi-Fi bit hızı ayarı yalnız etkinleştirmede uygulanır) olay döngüsü işlem hattından önce yeni `config_id` ile `onReconfigure` çağırır ve `stream_config_reannounced` loglar. Aynı yol T-049'daki eski bir yarışı da kapatıyor (önceki oturum arada başka tercih kaydederse). Core testi tam bu sırayı canlandırıyor (`testFallbackBetweenHelloAndActivationForcesANewConfigID`), ayrıca eşleşme/yalnız bit hızı farkı/bilinmeyen cihaz/sınır testleri.
- **Dokunulan dosyalar:** Core: `Video/VideoSettings.swift`, `StreamSettings.swift` (yalnız belge), `StreamPrefsPolicy.swift`, `GameDisplayPolicy.swift` (yeni), `StreamPrefsStore.swift`, `DisplayLease.swift`, `EncoderKnobs.swift`. Host: `VirtualDisplay.swift`, `Video/VideoPipeline.swift`, `Session/StreamCoordinator.swift`, `Session/UserDefaultsStreamPrefsStore.swift` (yalnız belge). Testler: `Video/GameDisplayTests.swift` (yeni), `Video/EncoderKnobsTests.swift` (`ev=profile` beklenen satırına `display=2800x1840@2x`). `docs/LOGGING.md`, bu kart.
- **Varsayımlar:**
  - Doğal boyut ayrı saklanmıyor: `replacedNative` (yalnız oyun ekranında dolu) tek kaynak; `displayHiDPI = replacedNative == nil`, `nativeWidthPx = replacedNative?.widthPx ?? widthPx`. HiDPI ekran tanım gereği doğal ekran olduğundan mevcut lease testlerindeki `other.widthPx = 1920` hâlâ "farklı doğal boyut" sayılıyor; mevcut testlerin hiçbirinin beklentisi değişmedi (yalnız `ev=profile` tam satır testi yeni alanı içeriyor).
  - `applying` her zaman doğal ekrandan başlar (`onNativeDisplay`), böylece oyun → doğal ve oyun → başka oyun boyutu da doğru; geçerlilik doğal (HELLO) boyuta göre.
  - Etkin ölçek (`effectiveScalePermille`) yalnız oyun ekranında `1000·encodedWidth/nativeWidth`; doğal ekranda `scalePermille` aynen kalır (bugünkü bit hızlarıyla birebir).
  - Kayıt: ekran 0×0 iken 3 değer (eski build'ler okuyabilsin), oyun ekranında 5 değer yazılır; 2/3/5 okunur.
  - 700 ms kuralı genelleştirildi: `VirtualDisplay` her kaldırmanın (invalidate, deinit, init içinde başarısız kurulum) zamanını kaydeder; `obtainDisplay` her yeni ekrandan önce `DisplayRecreateGap.remainingUs` kadar bekler. Böylece kip değişimi, `teardown+create` (cihaz/doğal boyut değişimi) ve geri düşüş yolu da 700 ms'yi atlamıyor. Devralınan ekranın kaldırılması sonrası bekleme bugünkü gibi ~700 ms.
  - Geri düşüş tetikleyicisi yalnız `VirtualDisplayError` ve `gameDisplayUnavailable` (1x'te `modeSelected == false`). `ScreenCaptureError.displayNotFound` bilerek sayılmadı: ekran uykusunda da olur ve süreç boyunca oyun ekranını kapatırdı. İzin/encoder hataları da sayılmaz.
  - Geri düşüşte `ActiveSession.prefs` (hatırlanan ya da son uygulanan tercih) `allowGameDisplay: false` ile yeniden uygulanır, yeni `config_id` + `onReconfigure`, sonra `lease.sessionStarted` → `.create(native)`. `onVideoAttached` kurulumdan sonra `config_id`'yi yeniden denetler (eski bağlantı iptal, istemci yeniden açar).
  - Ek log alanı `stream_prefs … game_display=none|applied|rejected|disabled` (geçersiz isteğin loglanması için, PROTOCOL "loglanır"); `cadence_setup display[… mode=…]`, `display_created/pipeline_started … mode=`, `stream_session … display=`.
- **Test edilmeyenler / cihazda doğrulananlar (→ T-216):** Bu Mac'te sanal ekran kurulmadı, uygulama çalıştırılmadı. Cihazda doğrulanacaklar: (1) 1x ekran gerçekten 1848×1214 / 1400×920 / 2100×1380 @1x kuruluyor mu, `mode_selected=true`, `applied=1848x1214px 1848x1214pt 120Hz`; (2) doğal ↔ oyun geçişinde `display_recreate reason=mode_change` ve 700 ms sonra kurulum başarılı mı (aynı seri numarası); (3) `sizeInMillimeters` fiziksel panelde kalınca macOS'un 1x kipi kabul edip etmediği; (4) kalem/dokunma eşlemesi 1x'te doğru mu (`VirtualDisplayLocator` ölçek 1); (5) oyun modunda bekletme → geri dönüşte `[.reuse]`/yeniden kullanım, oyun modundan çıkarken bekletilmiş 1x ekranın doğala dönmesi; (6) `game_display_failed` yolu gerçek bir hatayla tetiklenmedi (yalnız Core karar testi); (7) `stream_config_reannounced` yolu cihazda hiç tetiklenmedi (normal bağlantıda çıkmamalı; çıkarsa istemci yeni config'le video bağlantısını yeniden açmalı).
- **Açık sorular:**
  - `game_display_failed` süreç boyunca kalıcı; kullanıcıya menüde bir işaret gösterilmiyor (kapsam dışı, gerekirse ayrı kart).
  - `InjectTest.swift` kendi `VirtualDisplay`'ini kuruyor (kapsam dışı dosya); yeni varsayılan parametreler sayesinde değişmedi, artık o da kaldırma zamanını kaydediyor.
