---
id: T-248
title: Probe — does the tablet's HEVC decoder scale with concurrent sessions? (1 vs 2 vs 3 decoders, full vs half frames)
status: review
phase: 6
owner: android-client-dev
depends_on: []
decisions: []
files:
  - probes/decoder-concurrency-probe/
  - probes/README.md
  - backlog/tasks/T-248-decoder-concurrency-probe.md
---

## Amaç

Kullanıcı 2026-10-05: çözücü sınırını aşmak için görüntüyü iki yarıya bölüp iki çözücü oturumunda çözmek mümkün mü? Tablet `media_codecs*.xml`: `OMX.hisi.video.decoder.hevc` `concurrent-instances max=16`, `performance-point-4096x2160=60`, ölçülmüş 1080p 258 fps (535 Mpx/s), 4K 71 fps (589 Mpx/s), 720p 267 fps (246 Mpx/s → kare başına ~3,7 ms sabit maliyet). Soru: eş zamanlı oturumlar toplam hızı artırıyor mu (çok çekirdek), yoksa aynı hattı mı paylaşıyor?

## Bağlam

- Ürün koduna dokunma. `probes/decoder-concurrency-probe/`: (a) Mac tarafı küçük Swift CLI (diğer problar gibi; `probes/hdr-probe/Sources/hdr-probe/EncodeBench.swift` VT kodlama örneği): gerçekçi içerikli (kayan yazı + fotoğraf hareketi) 8-bit HEVC klipler üretir, MateBridge'in hızlı profiline yakın ayarlarla (B-kare yok, düşük gecikme dışı hızlı yol, ~60 Mbps eşdeğeri): `full_2800x1840.h265` ve `half_1400x1840.h265` (ve isteğe bağlı `quarter`), her biri ~600 kare, Annex-B. (b) Android probu (`probes/hdr-probe/android` düzeninde ayrı paket `dev.matebridge.decprobe`): klipleri `/sdcard/Android/data/<pkg>/files/`'tan okur; N ∈ {1,2,3} eş zamanlı `MediaCodec` (her biri kendi iş parçacığında, aynı ya da farklı klip) mümkün olan en hızlı şekilde çözer; çıkış ya `ImageReader` (gösterimsiz, hemen bırak) ya da yüzeysiz ByteBuffer — ikisi de denensin; `KEY_OPERATING_RATE` Short.MAX ve `KEY_PRIORITY 0` (MateBridge T-222 gibi) ile. Ölçüm: her oturum ve toplam kare/s, Mpx/s, kare başına süre p50/p95; senaryolar: 1×full, 2×full, 1×half, 2×half, 3×half. Sonuç logcat'e `DECPROBE` etiketiyle tek satır özet + istenirse dosyaya.
- Probu orkestratör kuracak ve çalıştıracak (MateBridge kapalıyken, ~3 dk). Komutları README'ye yaz.
- check.sh Swift probunu derler; Android probu alt klasörde, elle derlenir (hdr-probe gibi) — README'de komut.
- Mac'te pencere açma, sanal ekran kurma; kısa VT kodlama serbest. adb/tablet yok.

## Kabul kriterleri

- [x] Swift CLI derlenir ve klipleri üretir (`~/.cache/matebridge-tools/data/decprobe/`); `./scripts/check.sh` geçer.
- [x] Android probu `assembleDebug` ile derlenir; README'de kurulum/çalıştırma/okuma komutları.
- [x] Handoff: beklenen sonuç yorumu (2×half toplam ≈ 2× 1×half Mpx/s → çok çekirdek; ≈ aynı → tek hat).

## Plan

1. **Swift CLI** `probes/decoder-concurrency-probe/` (SwiftPM, `check.sh` builds + tests it):
   - `DecProbeCore` (testable): `ClipSpec` listesi (full 2800×1840 @60 Mbps; `half` = sol yarı, `half_right` = sağ yarı 1400×1840 @30 Mbps; `quarter` = sol üst 1400×920 @15 Mbps; bit hızı alanla orantılı), uzunluk önekli → Annex-B dönüşümü, NAL bölme + erişim birimi (AU) sayımı (`first_slice_segment_in_pic_flag`), argüman ayrıştırma.
   - `decprobe-clips` (exe): içerik = tüm kareyi kaplayan prosedürel "fotoğraf" (yumuşak renk lekeleri + gren) 2,5/1,5 px/kare kayar; her yarıda bir beyaz metin paneli, farklı hızlarda dikey kayan yazı (Menlo/Helvetica). Yarım/çeyrek klipler aynı sahnenin kırpıntısıdır (aynı çizim, öteleme ile) → 2×half (sol+sağ) gerçek bölme senaryosunun aynısı. VT: donanım HEVC Main 8-bit, hızlı profil (LLRC yok, RealTime=false, B-kare yok, PrioritizeSpeed, ExpectedFrameRate 120, DataRateLimits 2×), tek IDR (kare 0), 600 kare. Klipler sırayla kodlanır (tek oturum aynı anda). Çıktı Annex-B, IDR önüne VPS/SPS/PPS; yazdıktan sonra dosya yeniden okunup AU sayısı = kare sayısı doğrulanır. Varsayılan dizin `~/.cache/matebridge-tools/data/decprobe/`.
2. **Android probu** `probes/decoder-concurrency-probe/android` (hdr-probe düzeni, paket `dev.matebridge.decprobe`, elle derlenir):
   - Saf Kotlin + JVM testleri: `AnnexB` (NAL bölme, AU gruplama, csd-0 çıkarma), `ClipFiles` (ad → boyut), `Scenario` (`2xhalf` → half+half_right, `3xhalf` → half+half_right+half, açık `a+b` biçimi), `Stats` (p50/p95, özet satırı).
   - `DecProbeActivity`: klipleri `getExternalFilesDir` altından okur; senaryo × çıkış (`image` = `ImageReader` PRIVATE, hemen kapat; `buffer` = yüzeysiz ByteBuffer, render'sız bırak) için N `MediaCodec`'i ayrı iş parçacıklarında, ortak başlangıç mandalıyla, klibi döngüleyerek en hızlı şekilde çözer (`KEY_PRIORITY 0`, `KEY_OPERATING_RATE` Short.MAX). Isınma (1 s) sonrası ortak pencerede oturum başına ve toplam fps, Mpx/s, giriş→çıkış süresi ve çıkışlar arası süre p50/p95. `DECPROBE` etiketiyle senaryo başına tek satır + `files/decprobe-results.txt`. Extras: `scenarios`, `outputs`, `seconds`, `warmup`, `codec`, `prio`. `onPause`'da her şey durur.
3. README (probes/README.md satırı + prob README'si: derleme, push, çalıştırma, okuma komutları), `./scripts/check.sh`, `assembleDebug testDebugUnitTest`, Handoff.

## Handoff

- **Commit:** `2bb3a90` (uygulama; plan `d5f5eaf`), dal `task/T-248-decoder-probe`.
- **Dosyalar:** `probes/decoder-concurrency-probe/` (Swift paketi: `DecProbeCore` + `decprobe-clips` + testler; `android/` Gradle projesi, `dev.matebridge.decprobe`; `README.md`), `probes/README.md` (satır), bu kart.
- **Doğrulama:** `./scripts/check.sh` ALL OK (Swift probu derlendi + 4 test). Android: `assembleDebug testDebugUnitTest` geçti (10 JVM testi; `RealClipTest` gerçek klipleri ayrıştırdı: her biri 600 AU, csd-0 var). APK: `probes/decoder-concurrency-probe/android/app/build/outputs/apk/debug/app-debug.apk`.
- **Klipler üretildi** (`~/.cache/matebridge-tools/data/decprobe/`, 600 kare, tek IDR, `pictures=600 irap=1 errors=0`): `full_2800x1840.h265` 37,6 MB (60,2 Mbps @120), `half_1400x1840.h265` 18,9 MB (30,2), `half_right_1400x1840.h265` 18,8 MB (30,1), `quarter_1400x920.h265` 9,4 MB (15,1). Kodlama klip başına 1–4 s. İçerik `--preview 300` ile PNG'den gözle kontrol edildi (kayan fotoğraf + iki yazı paneli; sağ yarı kırpıntısı tam karenin sağ yarısıyla aynı).
- **Varsayımlar:** 120 fps hız kontrolü + 60 Mbps (ürünün 120 fps varsayılanı, `StreamPrefsPolicy`); kırpıntılar aynı bit/piksel. Yarım klipler sol/sağ kırpıntı olduğu için `2xhalf` = gerçek bölme. Ölçüm asenkron `MediaCodec` (oturum başına `HandlerThread`), klip IDR'den döngülenir; csd-0 ayrıca verilir, ilk AU'da parametre kümeleri de durur. `image` = `ImageReader` PRIVATE + `USAGE_GPU_SAMPLED_IMAGE` (maxImages 4, hemen kapat). `KEY_PRIORITY 0`, `KEY_OPERATING_RATE` Short.MAX, `KEY_FRAME_RATE` 120. Ek olarak (kartta yoktu, ucuz): `pace=120` tempolu besleme ile saf kare başına çözme süresi; `thermal` durumu satıra eklenir.
- **Test edilmeyen:** tabletteki hiçbir şey (adb yok). Çözücünün akışı kabul ettiği, 3 oturumun `priority 0` ile açılabildiği, HarmonyOS'ta `Android/data/<pkg>/files`'a `adb push`'un çalıştığı (hdr-probe'da çalışmıştı) cihazda görülecek. Mac'te klip çözümü denenmedi (yalnız AU/IRAP sayımı).

### Orkestratör: tablette (MateBridge istemcisi kapalı, ekran açık, tek cihaz testi, ~3 dk)

```bash
ADB=~/Library/Android/sdk/platform-tools/adb
D=~/.cache/matebridge-tools/data/decprobe
P=/sdcard/Android/data/dev.matebridge.decprobe/files
$ADB shell am force-stop dev.matebridge.client
$ADB install -r probes/decoder-concurrency-probe/android/app/build/outputs/apk/debug/app-debug.apk
$ADB shell mkdir -p $P
for f in full_2800x1840 half_1400x1840 half_right_1400x1840 quarter_1400x920; do $ADB push $D/$f.h265 $P/; done
$ADB logcat -c
$ADB shell am start -n dev.matebridge.decprobe/.DecProbeActivity          # 5 senaryo × image,buffer × 8 s ≈ 100 s
sleep 125
$ADB logcat -d -s DECPROBE:I | grep -E "DECPROBE (scen|info|done|aborted)"
$ADB shell am force-stop dev.matebridge.decprobe
$ADB logcat -c
$ADB shell am start -n dev.matebridge.decprobe/.DecProbeActivity --es pace 120 --es outputs image --es scenarios 1xfull,1xhalf,2xhalf
sleep 40
$ADB logcat -d -s DECPROBE:I | grep -E "DECPROBE (scen|done|aborted)"
$ADB shell am force-stop dev.matebridge.decprobe
```

Kontrol: `info clip … units=600`; çözücü `OMX.hisi.video.decoder.hevc`; her `scen=` satırında `ok=n` (ERR yoksa), `img` ≈ kare sayısı; `DECPROBE done`. `ERR(configure:…)` çıkarsa `--es prio none --es oprate none` ile tekrar.

### Beklenen sonuç yorumu

- `2xhalf total_mpxs ≈ 2 × 1xhalf total_mpxs` ve `2xhalf min_fps ≈ 1xhalf fps` → çok çekirdek: bölme kare hızını artırır; `pace=120` koşusunda `2xhalf lat` ≈ `1xhalf lat` < `1xfull lat` ise gecikme de düşer.
- `2xhalf total_mpxs ≈ 1xhalf total_mpxs` (oturum başına yarı hız) → tek hat zaman paylaşımı: bölme kazanç getirmez (kare başına ~3,7 ms sabit maliyet iki kez ödenir); `2xhalf min_fps` < `1xfull fps` bile olabilir.
- Arası (1,3–1,6×) → kısmi paralellik. `2xfull` aynı soruyu tam boyutta, `3xhalf` doygunluğu gösterir. Ürün yüzeye çizdiği için `image` sayıları esas; `buffer` farkı kopya maliyeti.

## Open questions

- `scripts/check.sh` alt klasördeki Android problarını (hdr-probe, bu prob) derlemiyor; bilinçli (kart öyle diyor), not olarak.
