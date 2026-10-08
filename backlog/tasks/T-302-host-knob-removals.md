---
id: T-302
title: Host — kapanmış deney anahtarlarını kaldır (BITRATE_STEP + canlı bit hızı zinciri, QUALITY, ENCODER=llrc, REFRESH, WIFI_BITRATE_KBPS, CHROMA 444/sharp_bilinear)
status: review
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

1. Core: `EncoderProfile` silinir (tek profil `fast`); `ChromaPolicy.resolve` `codec`/`profile` parametrelerini yitirir; `ChromaMode` `444`/`sharp_bilinear`, `ChromaFallbackReason` `llrc`/`codec`/`profileRejected`; `SharpYUV.Upsample.bilinear` + kernel `mode` (0 duz, 1 nearest); `EncoderKnobs` quality/bitrateStep; `EncoderSubmitOrder` bit hizi zinciri; `TransportBitrate` env yolu; `defaultRefreshHz`/`parseRefreshHz`.
2. Host: HEVCEncoder/PackedAuxEncoder/VideoPipeline/StreamCoordinator ayni VT ozellik sirasiyla sadelesir.
3. Yeni saf `RemovedKnobs` (Core) + HEVCEncoder'da bir kez `knob_ignored name= value=` uyarisi.
4. Testler: yalniz kaldirilan yollar silinir/duzeltilir, T-162 siralama testleri kalir.

## Handoff

- **Branch:** `task/T-302-knob-removals`; commit SHA asagida (son commit).
- **check.sh:** ALL OK (swift test 1027 test, gradle, fixtures, crypto, measurement kit).
- **Kaldirilanlar (hepsi kodu okuyarak dogrulandi):**
  - `MATEBRIDGE_BITRATE_STEP` + canli bit hizi zinciri: `BitrateStepKnob`, `VideoPipeline.setTargetBitrate`, `HEVCEncoder.setTargetBitrate/applyBitrate/bitrateStepTick/stepTimer`, `Backend.setBitrate`, `PackedAuxEncoder.setBitrate/currentKbps/logSink`, `CompressionBackend.setBitrate`, `BitrateRequest`, `PendingBitrate`/`openBitrate`/`takeBitrate`, bit hizi `Stats` alanlari, `ev=bitrate_set`. `LiveBitrateTests` ve 5 EncoderSubmitOrder bit hizi testi silindi; T-162 testleri (tek gonderim sahibi, barrier, stress) kaldi. `RateLimitWindows`/`MATEBRIDGE_RATE_WINDOW_MS` kaldi.
  - `MATEBRIDGE_QUALITY`: `qualityApplied`, `quality_rejected`, `EncoderKnobs.quality/parseQuality`. `ev=encoder_config` icinde `quality=unset` ve `quality_applied=0` sabit alan olarak KALDI (ayristiricilar degismesin).
  - `MATEBRIDGE_ENCODER=llrc`: `EncoderProfile` tipi tamamen silindi; HEVCEncoder/PackedAuxEncoder LLRC dallari, `ChromaFallbackReason.llrc`. `encoder_profile=fast` log alani sabit.
  - `MATEBRIDGE_REFRESH`: `parseRefreshHz`, `defaultRefreshHz` parametresi (applying, initialSettings, revalidated x2, StreamCoordinator 8 yer). Kural: 60 Hz, 120/144 fps'te fps'e esit; `applyingExperimentKnobs` `MATEBRIDGE_FPS=120` -> 120 Hz.
  - `MATEBRIDGE_WIFI_BITRATE_KBPS`: `applyingTransportKnobs`, `BitrateSource.wifiEnv`, `bitrateOverrideSource` alani; `settings(for:transport:)` artik transport almaz.
  - `MATEBRIDGE_CHROMA` `444` (`yuv444`, `main444ProfileLevel`, `profileRejected`, `ChromaFallbackReason.codec`) ve `sharp_bilinear` (`Upsample.bilinear`, CPU referans dali, Metal `mode` dali). Artik gecersiz deger gibi: `420`, `isSet`, `invalid`. Metal `sharp_luma` `mode` sayilari yeniden numaralandi (0 duz, 1 nearest); host ve test ayni `lumaMode` fonksiyonunu kullanir. `SharpYUVTests` GPU/CPU bit-exact karsilastirmasi nearest icin gecer.
- **knob_ignored:** `RemovedKnobs.present(env)` (Core, saf, test edilmis); HEVCEncoder encoder olusurken (her akis baslangici) `warning` `ev=knob_ignored name=<NAME> value=<log-safe>` yazar (`MATEBRIDGE_CHROMA` icin yalniz 444 / sharp_bilinear degerinde). `knobAllowList` (ev=profile `knobs=`) kaldirilan degiskenleri artik listelemez.
- **Ayni VT ozellikleri:** HEVCEncoder.init ve PackedAuxEncoder.init'in VTSessionSetProperty sirasi/degerleri diff'te bire bir ayni (RealTime=false, LLRC spec yok, AverageBitRate, DataRateLimits, ...). `--encode-bench`/`--dump-video` CALISTIRILMADI: `--dump-video` sanal ekran ister, `--encode-bench` ise HEVCEncoder'i kullanmaz (kendi sentetik oturumlari, bu degisiklikten etkilenmez) ve canli ana makinenin donanim kodlayicisini mesgul ederdi. Onceki/sonraki karsilastirma gerekirse orkestrator cihazda `ev=encoder_config` + `ev=profile` satirlarini main ile karsilastirsin.
- **Dokunulmayanlar:** `VirtualDisplay.swift` (`VD_TRANSFER`, T-304), `EncodeBench` katalogundaki `llrc`/`nolat-rtoff-q80` bench konfigurasyonlari (bench aracinin kendi katalogu, env anahtari degil), `--refresh` (VideoDump CLI bayragi), `PackedChroma` CPU referansi (A9 baska kart).
- **Belgeler icin onerilen metin (orkestrator):**
  - KNOBS.md: `MATEBRIDGE_BITRATE_STEP`, `MATEBRIDGE_QUALITY`, `MATEBRIDGE_ENCODER`, `MATEBRIDGE_REFRESH`, `MATEBRIDGE_WIFI_BITRATE_KBPS` satirlari "removed T-302 (inert, logs ev=knob_ignored)"; `MATEBRIDGE_CHROMA` degerleri yalniz `420 | sharp_nearest | packed444`; `444` ve `sharp_bilinear` removed.
  - LOGGING.md: yeni `encoder ev=knob_ignored` (W) `name= value=`; `ev=bitrate_set` ve `ev=quality_rejected` kaldirildi; `ev=encoder_config` `encoder_profile=fast`, `quality=unset`, `quality_applied=0` sabit (isterseniz sonra tamamen cikarilir; parser'lar henuz bekliyor olabilir); `bitrate_source=` degerleri `prefs|env|user` (`wifi_env` kalkti); `chroma_config reason=` degerleri `llrc`, `codec`, `profile_rejected` kalkti; `ev=chroma_config requested=444|sharp_bilinear` artik uretilmez.
  - 0023 ve 0026/0033 eklerine: BITRATE_STEP zinciri ve canli bit hizi ayari kaldirildi; sabit profil.
- **Cihazda dogrulanacak:** host yeniden baslatilinca (a) `ev=encoder_config` ve `ev=profile` ayni VT sonucunu gosteriyor, (b) Tam renk (packed444) ve `sharp_nearest` gorunumu degismedi (Metal kernel `mode` degisti: kernel derlenmeli, `chroma_fallback`/`metal_unavailable` gorulmemeli), (c) ortamda eski degisken kalmissa `knob_ignored` satiri var.

## Open questions
