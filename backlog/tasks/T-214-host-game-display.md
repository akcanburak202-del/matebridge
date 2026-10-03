---
id: T-214
title: Host: 1x game display at the requested pixel size (decision 0029)
status: todo
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

- [ ] [XCTest] Geçerli boyut → 1x 1848×1214, STREAM_CONFIG px = pt = 1848×1214, ölçek yok sayılır; geçersiz (tek sayı, doğaldan büyük, yarıdan küçük, en-boy > %0,5, bir boyut 0) → doğal HiDPI; `display=0` → bugünküyle aynı STREAM_CONFIG.
- [ ] [XCTest] Varsayılan bit hızı 1848 için 660 değeriyle aynı; 5'li kayıt gidip gelir, 2/3'lü eski kayıtlar okunur.
- [ ] [XCTest] Lease: aynı cihaz + doğal boyut, farklı kip → `.reconfigure` (aktif ve bekletilmiş); farklı doğal boyut → teardown+create. `obtainDisplay` yalnız tam eşleşmede yeniden kullanır (saf karar fonksiyonu Core'da).
- [ ] [XCTest] 1x hatasında tek doğal geri düşüş.
- [ ] [doc] LOGGING yeni alanlar. `VirtualDisplay` tek CGVirtualDisplay dosyası. `./scripts/check.sh` yeşil.
- [ ] [device] T-216.

## Plan

_(Ajan kodlamadan önce doldurur.)_

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulananlar:**
- **Açık sorular:**
