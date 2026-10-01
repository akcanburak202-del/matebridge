---
id: T-086
title: Mac — kodlayıcı deney düğmeleri (H.264, bit hızı, kalite), boşta kalite tazeleme ve keskinlik ölçümü (T-082/T-085)
status: review
phase: 5
owner: mac-host-dev
depends_on: [T-082, T-085]
decisions: []
files:
  - host-mac/Sources/MateBridgeHost/Video/
  - host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift
  - host-mac/Sources/MateBridgeApp/main.swift
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

- [x] `MATEBRIDGE_CODEC=h264|hevc` (varsayılan hevc). h264'te `kCMVideoCodecType_H264`, profil `MATEBRIDGE_H264_PROFILE=high|main|cbp|high52` (varsayılan high = `kVTProfileLevel_H264_High_AutoLevel`; high52 = `High_5_2`; cbp = `ConstrainedBaseline_AutoLevel`), parametre kümeleri `CMVideoFormatDescriptionGetH264ParameterSetAtIndex` ile (SPS+PPS). `VideoPipeline` `.h264`'ü kabul eder; STREAM_CONFIG codec=1 taşır. İlk CODEC_CONFIG'te log: `ev=encoder_config codec=h264 profile=… level_idc=…` (H.264 SPS'in 3. baytı; HEVC için de codec yazılır). `StreamCoordinator`'daki sabit `codec=hevc` düzeltilir. Protokol/fikstür değişmez.
- [x] `MATEBRIDGE_BITRATE_KBPS` verilirse prefs'ten gelen varsayılan bit hızını **ezer** (env > prefs), 20–80 Mbps sınırı env için 5–150 Mbps. Açılışta log: `ev=encoder_config bitrate_kbps=… source=env|prefs`.
- [x] `MATEBRIDGE_PRIO_SPEED=0|1` (varsayılan 1 = bugünkü). 0 iken `PrioritizeEncodingSpeedOverQuality=false`.
- [x] `MATEBRIDGE_QUALITY=0.0..1.0` (varsayılan yok). Verilirse `kVTCompressionPropertyKey_Quality` ayarlanır, `AverageBitRate` ayarlanmaz, `DataRateLimits` tavanı korunur. VT reddederse (OSStatus) log'a yazılır, bitrate yoluna düşülür.
- [x] `MATEBRIDGE_IDLE_REFRESH_MS=N` (varsayılan 0 = kapalı). Son gerçek yakalamadan N ms sonra içerik değişmemişse son yakalanan tampon `resubmitLast()` yoluyla (kapı atlanarak) **K kez** (`MATEBRIDGE_IDLE_REFRESH_COUNT`, varsayılan 3, kareler arası 1 kare aralığı) yeniden kodlanır. Gerçek bir yakalama karesi gelince sayaç sıfırlanır, aynı durağan bölümde tekrar yapılmaz. Değişken: `MATEBRIDGE_IDLE_REFRESH_KEY=1` ise yeniden gönderim yerine tek bir zorunlu anahtar kare. Log: `ev=idle_refresh frames=K` (bölüm başına bir, debug seviyesinde yeterli).
- [ ] Boşta tazeleme tablet tarafında sorun çıkarmaz: aynı PTS'li ya da sırası bozuk kare üretilmez (yeniden gönderilen kareler artan PTS ile). Tablet hattı (pacer) bunları normal kare gibi işler.
- [x] `--encode-bench`'e `.fast` profiline uyan varyantlar eklenir: `nolat-rtoff` (bugünkü), `nolat-rtoff-noprio`, `nolat-rtoff-q80` (Quality 0.8). Kodlama süresi p50/p95/p99 ve kare başı bayt raporlanır. Bench `MATEBRIDGE_CODEC`'i de okur (H.264 kodlama süresi ölçülebilsin).
- [x] Yeni CLI kipi `--sharpness-bench` (ek bağımlılık yok):
  - 2800×1840 sentetik metin deseni üretir (CoreText, farklı punto, gri ve renkli yazı, ince çizgiler). Desen kaydırılarak N kare hareket verilir, ardından durağan bölüm gelir.
  - Mevcut kodlayıcı ayarlarıyla kodlar, `VTDecompressionSession` ile süreç içinde çözer.
  - Son hareket karesi, durağan son kare ve boşta tazeleme sonrası kare için kaynağa karşı **luma PSNR** ve basit SSIM (8×8 pencere) raporlar.
  - Bit hızı, PRIO_SPEED, QUALITY ve IDLE_REFRESH düğmelerini aynı env adlarıyla okur. Çıktı tek satır sonuç başına, `key=value`.
- [x] Saf mantık (codec/profil ayrıştırma, env ayrıştırma ve öncelik, boşta tazeleme durum makinesi, PSNR/SSIM hesabı) `MateBridgeCore` içinde ve testli.
- [x] `./scripts/check.sh` geçiyor.

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


- **Commit:** `811b003` (uygulama), `f33fde7` (plan), inceleme düzeltmeleri `988e93e`. Dal `task/T-086-encoder-knobs`, `main` d1ab2bd üzerinde.
- **check.sh:** ALL OK (host-mac 194 XCTest + 508 swift-testing; yeni `EncoderKnobsTests` 24 test).
- **Dosyalar:**
  - Yeni (Core): `MateBridgeCore/Video/EncoderKnobs.swift` (`EncoderKnobs`, `H264Profile`, `IdleRefreshConfig`,
    `IdleRefreshPolicy`, `ResubmitStamp` (yeniden gönderim damgası = now + lead), `H264SPS`, `HEVCSPS.generalLevelIdc`, `VideoSettings.parseCodec/bitrateSource`),
    `ImageQuality.swift` (PSNR, 8×8 SSIM, isteğe bağlı "yalnız detaylı blok" filtresi), `SharpnessBenchOptions.swift`.
  - Değişen (Core): `VideoSettings.swift` (`bitrateOverrideKbps`, codec knob), `StreamPrefsPolicy.swift`
    (`applying` → `override ?? default`), `EncodeBench.swift` (`quality`, 2 varyant, `applyingEnvironment`).
  - Host: `Video/HEVCEncoder.swift` (ad korundu; codec/profil/parametre kümesi, PRIO, QUALITY, boşta tazeleme,
    `encoder_config` logları, `logSink`), `Video/VideoPipeline.swift` (`.h264` kabul), `Video/EncodeBench.swift`
    (codec/quality, KB/frame sütunu), yeni `Video/SharpnessBench.swift`, `Session/StreamCoordinator.swift`
    (`codec=` + `bitrate_source=` logları), `MateBridgeApp/main.swift` (+1 satır).
  - Test: `Tests/MateBridgeCoreTests/Video/EncoderKnobsTests.swift`.
- **Varsayımlar / kararlar:**
  - Kartta yazan `MateBridgeHost/main.swift` yok; `MateBridgeApp/main.swift`'e yalnız `SharpnessBench.runIfRequested()` eklendi.
  - Log'lar `HostLog` (component `encoder`, `host.log`) üzerinden: açılışta
    `ev=encoder_config codec=… encoder_profile=fast|llrc bitrate_kbps=… source=env|prefs prio_speed=… quality=… idle_refresh=… quality_applied=…`,
    parametre kümesi her değiştiğinde `ev=encoder_config codec=… profile=main|high|… level_idc=… sets=…`.
    `ev=idle_refresh frames=K` (ya da `frames=1 mode=key`) **info** seviyesinde (debug `host.log`'a yazılmıyor; bölüm başına tek satır, yalnız knob açıkken).
  - `bitrate_source=prefs`, prefs gelmeden önceki başlangıç değeri (tabletDefault 30 Mbps) için de kullanılıyor.
  - Boşta tazeleme ayrı bir timer'la 1 kare aralığında yoklanıyor (yalnız knob açıkken). Gerçek kare = `encode()`; yeniden gönderimler sayacı kurmaz.
  - Yeniden gönderimler (boşta tazeleme ve mevcut keyframe resubmit) artık `now + lead` damgalı; `lead` = son gerçek
    yakalamanın `captureTimeUs - deliveredUs` değeri (SCK PTS teslimden ~+6,6 ms ileride). Damga her zaman verilmiş son
    damgadan büyük (`max(…, son + 1)`). Böylece tablet AdaptivePacer'ında `x = ready - capture` gerçek karelerle aynı
    (testli). Gerçek karelerin damgalarına dokunulmuyor. Bu, mevcut keyframe resubmit'in damgasını da değiştiriyor
    (eskiden `now`, ~6,6 ms "geç" görünüyordu).
  - `nolat-rtoff-noprio` ve eski `no-prioritize` artık özelliği açıkça `false` yapıyor (önceden hiç set edilmiyordu; VT varsayılanı da false).
  - `--encode-bench` ayrıca `MATEBRIDGE_BITRATE_KBPS` okur (tüm config'lerin bit hızını ezer); uygulama 120 fps'te 60 Mbps kullandığından ölçümler bununla da alındı.
- **Bench sonuçları (M6, debug build, 2026-10-01):**
  - `--sharpness-bench` (2800×1840@120, 30 hareket karesi × 6 px kaydırma, 600 ms durağan; PSNR/SSIM son kareye göre):

    | env | motion_mean PSNR (kare) | motion_last PSNR / B | idle refresh | static_end PSNR |
    |---|---|---|---|---|
    | varsayılan (hevc, 60 Mbps prefs, prio=1) | 36.78 (30/30) | 42.15 / 23 KB | — | 42.15 |
    | `IDLE_REFRESH_MS=300` | 36.78 | 42.15 | n1 43.62 (191 KB), n2 45.49 (255 KB), n3 45.78 (50 KB) | **45.78** |
    | `IDLE_REFRESH_MS=300 KEY=1` | 36.78 | 42.15 | key 40.43 (**1.45 MB**) | 40.43 (daha kötü) |
    | `PRIO_SPEED=0` | 46.99 (**24/30**, enc 18–24 ms) | 52.43 / 5 KB | — | 52.43 |
    | `PRIO_SPEED=0 IDLE_REFRESH_MS=300` | 47.32 (26/30) | 52.44 | 3× ~0.2–0.5 KB, değişim yok | 52.44 |
    | `QUALITY=0.8` (quality_applied=1) | 38.61 (30/30) | 45.64 / 140 KB | — | 45.64 |
    | `CODEC=h264` (high, level_idc=60) | 41.71 (**26/30**, enc ~17.6 ms) | 46.82 / 16 KB | — | 46.82 |
    | `CODEC=h264 IDLE_REFRESH_MS=300` | 41.86 (27/30) | 46.94 | 3× ~1–1.6 KB, +0.02 dB | 46.96 |
    | `BITRATE_KBPS=100000` (source=env) | 43.24 (30/30) | 51.63 / 121 KB | — | 51.63 |

    SSIM bu sayfada doygun (0.998–0.9999); ayırt edici olan PSNR. `ssim_text` yalnız kaynak varyansı ≥100 olan 8×8 blokları sayar.
  - `--encode-bench --fps 120 --seconds 3`, scroll içerik (enc ms p50/p95/p99, paced 120 satırı):

    | env / config | nolat-rtoff | nolat-rtoff-noprio | nolat-rtoff-q80 |
    |---|---|---|---|
    | hevc, 30 Mbps | 6.1/6.5/12.6, 119.7 fps, 31 KB/kare | 24.5/28.5/32.0, **103 fps** (48 atlandı) | 6.2/6.6/12.6, 119.7 fps, 42 KB/kare, 39.8 Mbps |
    | hevc, 60 Mbps | 6.3/6.7/12.7, 119.7 fps, 62.5 KB | 25.5/29.3/33.3, **100 fps** | 6.5/7.9/15.5, 119.7 fps, 83 KB, 79.6 Mbps |
    | h264 high, 60 Mbps | 24.4/28.7/33.1, **103 fps** (49 atlandı) | 24.2/28.3/30.0, 103 fps | 25.3/29.6/34.3, 100 fps |
    | h264 high52, 60 Mbps | **her kare başarısız** (120 fps level 5.2 MB/s sınırını aşıyor) | aynı | aynı |

    Ek: `h264 high52 --fps 60` çalışıyor (paced p50 17.9 ms); `h264 high --fps 60` paced p50 22.9 ms.
- **Bulgular (orkestratör için, karar değil):**
  - H.264 donanım kodlayıcısı 2800×1840'ta ~24 ms/kare → **120 fps'e yetişmiyor** (~103 fps tavan); T-082'de çözme kazancı bunu telafi etmeli. `high52`'yi 120 fps'te kullanmak akışı keser (encoder 5 ardışık hatada pipeline'ı düşürür).
  - `PRIO_SPEED=0` kalitede büyük kazanç (+10 dB), ama kodlama ~25 ms → 120 fps'te kare kaybı; 60 fps için aday.
  - Boşta tazeleme (P-kare, K=3) prio=1'de durağan metni +3.6 dB iyileştiriyor, bedeli bölüm başına ~0.5 MB patlama. Anahtar kare varyantı hem büyük hem kötü.
  - `QUALITY=0.8` hızı korur, kaliteyi artırır ama ortalama bit hızı ~1.33× (DataRateLimits tavanı aktif).
- **Test EDİLMEDİ (cihaz/izin gerekli):**
  - Uygulamanın gerçek oturumda knob'larla çalışması (host yeniden başlatılmadı, `bundle-host.sh` çalıştırılmadı).
  - Tablette H.264 akışı: `STREAM_CONFIG codec=1` + SPS/PPS CODEC_CONFIG ile `OMX.hisi.video.decoder.avc`'nin level 6.0 (level_idc=60) akışı açıp açmadığı.
  - Boşta tazeleme karelerinin tablet pacer'ında sorunsuz işlendiği (kabul kriteri 38, cihazda doğrulanmalı); `ev=idle_refresh` satırları ve tablet tarafında kare düşmesi/sıra hatası olmaması.
  - Tablette yazma duraklamalarından sonra pacer p99/kilit payının boşta tazelemeyle bozulmadığı (`now + lead` damgası).
- **İnceleme düzeltmeleri (orkestratör incelemesi, 2026-10-01):**
  1. Yeniden gönderim damgası `now` → `now + lead` (yukarıda). Test: `testResubmissionKeepsTheRealFramesLead`,
     `testResubmissionStampsIncreaseAndHandleNegativeLead`.
  2. İlk sürümdeki `ResubmitStamp.Tracker` (resubmit'ten sonra teslim edilen gerçek kareyi `son + 1`'e taşıyan kural)
     **kaldırıldı**. SCK PTS teslimden ileride olduğu için gözlenen zamanlamada hiç tetiklenmiyordu, `now + lead` ile de
     gereksiz. Handoff'taki "varsayılan davranışta hata düzeltmesi" iddiası **yanlıştı**, geri alındı. Kalan teorik pencere:
     lead, resubmit ile hemen sonraki gerçek kare arasında (resubmit→teslim aralığından fazla) küçülürse o gerçek kare
     pacer'da "stale" düşebilir. Gözlenmedi, ölçülmedi.
  3. Yarış: `resubmitLast()` artık `last`'ı okuma ile pacer'a sunmayı tek kilit altında yapıyor (`offerLocked` + `perform`),
     bu yüzden eski bir tampon `last`'taki daha yeni kareyi ezemez.
  4. `files:` listesindeki var olmayan `MateBridgeHost/main.swift` → `host-mac/Sources/MateBridgeApp/main.swift`.
  - Düzeltmeden sonra tekrar ölçüldü (`IDLE_REFRESH_MS=300`): motion_last 42.52 → n1 43.78, n2 45.56, n3 **46.01** dB
    (static_end). `KEY=1`: 39.59 dB, 1.38 MB. Önceki tabloyla tutarlı.
- **Açık sorular:** yok.
