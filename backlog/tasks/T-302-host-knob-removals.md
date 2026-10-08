---
id: T-302
title: Host — kapanmış deney anahtarlarını kaldır (BITRATE_STEP + canlı bit hızı zinciri, QUALITY, ENCODER=llrc, REFRESH, WIFI_BITRATE_KBPS, CHROMA 444/sharp_bilinear)
status: todo
phase: 7
owner: mac-host-dev
depends_on: []
decisions: [0023, 0026, 0033]
files:
  - host-mac/Sources/MateBridgeCore/Video/
  - host-mac/Sources/MateBridgeCore/Session/
  - host-mac/Sources/MateBridgeHost/Video/
  - host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift
  - host-mac/Sources/MateBridgeHost/main.swift
  - host-mac/Tests/MateBridgeCoreTests/
  - backlog/tasks/T-302-host-knob-removals.md
---

## Amaç

T-297 ortak ayıklaması, kullanıcı kararları 2026-10-08 (0023, 0026, 0033 ekleri). Kanıtlar: `docs/reviews/2026-10-08/agents/simp-a-host-video.md` (A1, A12) ve `simp-f-knobs.md` (host tablosu).

## Kabul

1. **`MATEBRIDGE_BITRATE_STEP`** ve yalnız onun ulaştığı canlı bit hızı zinciri kaldırılır:
   - `VideoPipeline.setTargetBitrate`;
   - `HEVCEncoder.setTargetBitrate`/`applyBitrate`/`stepTimer`, `Backend.setBitrate`;
   - `PackedAuxEncoder.setBitrate`/`currentKbps`;
   - `EncoderSubmitOrder` içindeki `BitrateRequest`, `setBitrate`/`takeBitrate`, `PendingBitrate`, `openBitrate` ve bit hızı istatistikleri.

   EncoderSubmitOrder'ın tek gönderim sahibi düzeni (T-162) ve sınama kancaları **kalır**. `RateLimitWindows`/`dataRateLimits` ve **`MATEBRIDGE_RATE_WINDOW_MS` kalır** (EN9 ölçümü bekliyor).
2. **`MATEBRIDGE_QUALITY`:** `qualityApplied` dalları kaldırılır. `ev=encoder_config` içindeki `quality=unset` alanı sabit kalabilir ya da çıkar; LOGGING önerisini Handoff'a yaz.
3. **`MATEBRIDGE_ENCODER=llrc`:** LLRC tanım dalları (HEVCEncoder, PackedAuxEncoder, `ChromaMode` `reason=llrc`) kaldırılır. `fast` tek profil olur; `encoder_profile=fast` log alanı sabit kalır.
4. **`MATEBRIDGE_REFRESH`:** okuma yerleri ve `defaultRefreshHz` parametresi kaldırılır. Varsayılan bugünkü 60 / akış fps kuralıyla aynı kalır.
5. **`MATEBRIDGE_WIFI_BITRATE_KBPS`:** `TransportBitrate` env yolu ve `bitrateSource=wifi_env` kaldırılır.
6. **`MATEBRIDGE_CHROMA`:** `444` (`yuv444`, `main444ProfileLevel`, `profileRejected` yolu) ve `sharp_bilinear` (`Upsample.bilinear` dalı ve kernel modu) kaldırılır. `420`, `sharp_nearest` ve paketli tam renk değişmez. Metal kaynağında bit-exact testler (`SharpYUVTests`) nearest için geçer.
7. **Bilinmeyen değerler:** kaldırılan env değerleri ya da değişkenleri artık etkisizdir; mümkünse `ev=profile`/başlangıçta bir kez `knob_ignored name=` uyarısı loglanır.
8. **Testler:** yalnız kaldırılan yolların testleri silinir; T-162 sıralama testleri kalır.
9. **Kapsam dışı:** `VirtualDisplay.swift` (`VD_TRANSFER`, T-304). Belgeler (`KNOBS.md`, `LOGGING.md`) orkestratörde; önerilen metni Handoff'a yaz.
10. Host hedefinin test hedefi yok. `--encode-bench` ve `--dump-video` çıktısı önce/sonra karşılaştırılır (aynı ayarlarda aynı VT özellikleri); Handoff'a yaz.

## Plan

## Handoff

## Open questions
