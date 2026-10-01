---
id: T-086
title: Mac — kodlayıcı deney düğmeleri (H.264, bit hızı, kalite), boşta kalite tazeleme ve keskinlik ölçümü (T-082/T-085)
status: in-progress
phase: 5
owner: mac-host-dev
depends_on: [T-082, T-085]
decisions: []
files:
  - host-mac/Sources/MateBridgeHost/Video/
  - host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift
  - host-mac/Sources/MateBridgeHost/main.swift
  - host-mac/Sources/MateBridgeCore/Video/
  - host-mac/Tests/
  - backlog/tasks/T-086-host-encoder-quality-knobs.md
---

## Amaç

T-085 araştırması (orkestratör, 2026-10-01):

- Akıcı mod gerçekte **60 Mbps** kullanıyor. `StreamPrefsPolicy.defaultBitrateKbps` = 30 000 × fps/60 × scale², 20–80 Mbps aralığına kırpılıyor.
- `MATEBRIDGE_BITRATE_KBPS` etkisiz: prefs gelince `applying()` onu eziyor.
- `PrioritizeEncodingSpeedOverQuality=true` sabit yazılı.
- Ekran durağanken kalite tazeleme **yok**. SCK yalnız değişimde kare veriyor, bu yüzden hareketin son (bulanık) P karesi ekranda kalıyor. Bu, yazı keskinliği için muhtemelen en büyük kazanç.

T-082 araştırması: protokol ve tablet H.264'ü uçtan uca destekliyor (`CODEC_H264=1`, `VideoRenderer.mime()` → AVC, CODEC_CONFIG tek tampon SPS+PPS). Yalnızca host HEVC'ye sabit: `HEVCEncoder.swift` codec türü/profil/parametre kümesi çıkarımı, `VideoPipeline.swift` `.hevc` dışını reddediyor, `StreamCoordinator` log'u `codec=hevc` sabit. Tablet çözücüsü `OMX.hisi.video.decoder.avc` 2.073.600 MB/s bildiriyor (4K60); 2800×1840@120 = 2,415 M MB/s → seviye 6.0 gerekir (resmi sınır dışı; denenecek).

Bu kart **deney düğmeleri** ekler. Her düğmenin varsayılanı bugünkü davranıştır. Varsayılanı değiştirmek, ölçümden sonra ayrı bir karar olacak.

## Kabul kriterleri

- [ ] `MATEBRIDGE_CODEC=h264|hevc` (varsayılan hevc). h264'te `kCMVideoCodecType_H264`, profil `MATEBRIDGE_H264_PROFILE=high|main|cbp|high52` (varsayılan high = `kVTProfileLevel_H264_High_AutoLevel`; high52 = `High_5_2`; cbp = `ConstrainedBaseline_AutoLevel`), parametre kümeleri `CMVideoFormatDescriptionGetH264ParameterSetAtIndex` ile (SPS+PPS). `VideoPipeline` `.h264`'ü kabul eder; STREAM_CONFIG codec=1 taşır. İlk CODEC_CONFIG'te log: `ev=encoder_config codec=h264 profile=… level_idc=…` (H.264 SPS'in 3. baytı; HEVC için de codec yazılır). `StreamCoordinator`'daki sabit `codec=hevc` düzeltilir. Protokol/fikstür değişmez.
- [ ] `MATEBRIDGE_BITRATE_KBPS` verilirse prefs'ten gelen varsayılan bit hızını **ezer** (env > prefs), 20–80 Mbps sınırı env için 5–150 Mbps. Açılışta log: `ev=encoder_config bitrate_kbps=… source=env|prefs`.
- [ ] `MATEBRIDGE_PRIO_SPEED=0|1` (varsayılan 1 = bugünkü). 0 iken `PrioritizeEncodingSpeedOverQuality=false`.
- [ ] `MATEBRIDGE_QUALITY=0.0..1.0` (varsayılan yok). Verilirse `kVTCompressionPropertyKey_Quality` ayarlanır, `AverageBitRate` ayarlanmaz, `DataRateLimits` tavanı korunur. VT reddederse (OSStatus) log'a yazılır, bitrate yoluna düşülür.
- [ ] `MATEBRIDGE_IDLE_REFRESH_MS=N` (varsayılan 0 = kapalı). Son gerçek yakalamadan N ms sonra içerik değişmemişse son yakalanan tampon `resubmitLast()` yoluyla (kapı atlanarak) **K kez** (`MATEBRIDGE_IDLE_REFRESH_COUNT`, varsayılan 3, kareler arası 1 kare aralığı) yeniden kodlanır. Gerçek bir yakalama karesi gelince sayaç sıfırlanır, aynı durağan bölümde tekrar yapılmaz. Değişken: `MATEBRIDGE_IDLE_REFRESH_KEY=1` ise yeniden gönderim yerine tek bir zorunlu anahtar kare. Log: `ev=idle_refresh frames=K` (bölüm başına bir, debug seviyesinde yeterli).
- [ ] Boşta tazeleme tablet tarafında sorun çıkarmaz: aynı PTS'li ya da sırası bozuk kare üretilmez (yeniden gönderilen kareler artan PTS ile). Tablet hattı (pacer) bunları normal kare gibi işler.
- [ ] `--encode-bench`'e `.fast` profiline uyan varyantlar eklenir: `nolat-rtoff` (bugünkü), `nolat-rtoff-noprio`, `nolat-rtoff-q80` (Quality 0.8). Kodlama süresi p50/p95/p99 ve kare başı bayt raporlanır. Bench `MATEBRIDGE_CODEC`'i de okur (H.264 kodlama süresi ölçülebilsin).
- [ ] Yeni CLI kipi `--sharpness-bench` (ek bağımlılık yok):
  - 2800×1840 sentetik metin deseni üretir (CoreText, farklı punto, gri ve renkli yazı, ince çizgiler). Desen kaydırılarak N kare hareket verilir, ardından durağan bölüm gelir.
  - Mevcut kodlayıcı ayarlarıyla kodlar, `VTDecompressionSession` ile süreç içinde çözer.
  - Son hareket karesi, durağan son kare ve boşta tazeleme sonrası kare için kaynağa karşı **luma PSNR** ve basit SSIM (8×8 pencere) raporlar.
  - Bit hızı, PRIO_SPEED, QUALITY ve IDLE_REFRESH düğmelerini aynı env adlarıyla okur. Çıktı tek satır sonuç başına, `key=value`.
- [ ] Saf mantık (codec/profil ayrıştırma, env ayrıştırma ve öncelik, boşta tazeleme durum makinesi, PSNR/SSIM hesabı) `MateBridgeCore` içinde ve testli.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

1. **Core (saf, testli)** — `MateBridgeCore/Video/EncoderKnobs.swift`:
   - `VideoSettings.parseCodec` (`h264|hevc`, varsayılan hevc), `H264Profile.parse` (`high|main|cbp|high52`).
   - `EncoderKnobs.parse(env)`: `prioritizeSpeed` (PRIO_SPEED, varsayılan true), `quality` (0.0...1.0 ya da nil),
     `h264Profile`, `IdleRefreshConfig` (DELAY ms, COUNT 1...30 varsayılan 3, KEY).
   - `VideoSettings.bitrateOverrideKbps` (env'den, `applyingExperimentKnobs` doldurur) + `bitrateSource` (`env|prefs`).
     `applying(prefs)` artık `override ?? defaultBitrateKbps(...)` kullanır → env > prefs. `applyingExperimentKnobs`
     `codec`'i de `MATEBRIDGE_CODEC`'ten alır → STREAM_CONFIG codec=1.
   - `IdleRefreshPolicy`: durum makinesi (`captured(nowUs)`, `tick(nowUs) -> .none/.resubmit(first)/.keyframe`):
     son gerçek yakalamadan N ms sonra K yeniden gönderim, aralarında 1 kare; bölüm başına bir kez; gerçek kare sıfırlar.
   - `H264SPS.levelIdc/profileIdc` ve `HEVCSPS.generalLevelIdc` (log için).
   - `ImageQuality.lumaPSNR` ve `ssim8x8` (örtüşmeyen 8×8 pencere, standart C1/C2).
   - `EncodeBenchConfig`: `quality` alanı + `nolat-rtoff-noprio`, `nolat-rtoff-q80`; `EncodeBenchOptions` env'den codec/profil.
   - `SharpnessBenchOptions.parse(args)` (`--motion-frames`, `--shift-px`, `--static-ms`, `--fps`).
2. **Host** — `HEVCEncoder` (ad korunuyor, artık HEVC/H.264): codec türü, H.264 profil, parametre kümeleri
   (`...GetH264ParameterSetAtIndex`), PRIO_SPEED, QUALITY (reddedilirse log + AverageBitRate yolu), ilk CODEC_CONFIG'te
   `ev=encoder_config codec profile level_idc`, açılışta `ev=encoder_config bitrate_kbps source prio_speed quality idle_refresh_ms`.
   Boşta tazeleme: etkinse kare aralığında tıklayan ayrı timer, `encode()` politikaya gerçek kareyi bildirir;
   `.resubmit` → `resubmitLast()` (kapı atlanır, `reserveSlot` PTS'yi artırır), `.keyframe` → `requestKeyframe(resubmitNow:)`.
   `VideoPipeline` `.h264`'ü kabul eder. `StreamCoordinator` log'u `codec=\(settings.codec)` + `bitrate_source`.
3. **Bench** — `EncodeBench` codec/quality'yi uygular, kare başı ortalama bayt ekler. Yeni `SharpnessBench.swift`
   (MateBridgeHost/Video): CoreText ile uzun metin tuvali → NV12 (BT.709 full), dikey kaydırmayla N hareket karesi
   gerçek `HEVCEncoder` ile (env düğmeleri aynen), Annex-B → `VTDecompressionSession` ile çözme, `static-ms` beklerken
   boşta tazeleme kareleri; satır başına `phase=motion_last|static_end|idle_refresh_i psnr_y=… ssim_y=… bytes=…`.
   `MateBridgeApp/main.swift` bir satır: `SharpnessBench.runIfRequested()`.
4. Testler (`Tests/MateBridgeCoreTests/Video/EncoderKnobsTests.swift`), `./scripts/check.sh`, bench'ler, Handoff.

Not: kartın `files:` listesindeki `host-mac/Sources/MateBridgeHost/main.swift` mevcut değil; CLI giriş noktası
`host-mac/Sources/MateBridgeApp/main.swift`. Bunu kastedilen dosya sayıp yalnızca bir satır ekliyorum.

## Handoff

