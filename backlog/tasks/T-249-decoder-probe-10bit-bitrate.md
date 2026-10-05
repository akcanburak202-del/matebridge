---
id: T-249
title: Probe — decoder headroom for 10-bit (SDR + HDR PQ) and high bitrates (60–150 Mbps) at 2800×1840
status: review
phase: 6
owner: android-client-dev
depends_on: [T-248]
decisions: [0032]
files:
  - probes/decoder-concurrency-probe/
  - probes/README.md
  - backlog/tasks/T-249-decoder-probe-10bit-bitrate.md
---

## Amaç

T-248 tablet çözücüsünün 8-bit 2800×1840 @60 Mbps'te ~356 fps verdiğini, 120 fps tempolu beslemede kare başına gecikmenin p50/p95 13,3/16,6 ms olduğunu gösterdi. "Çözücü sınırda" varsayımıyla konan sınırları kaldırmadan önce iki açık soru (NOTES 2026-10-05 ~17:20):

1. **10-bit:** HEVC Main10 (HDR10 PQ/BT.2020 ve SDR BT.709 10-bit) çözme kapasitesi ve gecikmesi 8-bit ile aynı mı? → 0032 "HDR yalnız Oyun 60" çekincesi, 10-bit SDR (bantlanma) fikri.
2. **Bit hızı:** 60 / 80 / 100 / 150 Mbps'te kapasite ve gecikme (özellikle p99/maks) nasıl değişiyor? → T-085'in +2–3 ms ve p99 40 ms bulgusu çözücüden mi geliyordu; Oyun/Çizim Otomatik 60 Mbps ve host 80 Mbps tavanı.

İsteğe bağlı (ucuz ise): IDR kare çözme gecikmesi (periyodik IDR'li klip) → kurtarma maliyeti.

## Bağlam

- Ürün koduna dokunma; yalnız mevcut prob genişletilir (`probes/decoder-concurrency-probe/`, Swift klip üreteci + Android `dev.matebridge.decprobe`). T-248 kartındaki düzen ve çalıştırma bloğu geçerli.
- **Klip üreteci:** bit derinliği/renk seçeneği (`8` mevcut; `10sdr` = Main10 BT.709; `10pq` = Main10 BT.2020/PQ, MDCV+CLL SEI — örnek: `probes/hdr-probe/Sources/hdr-probe/EncodeBench.swift` ve host HDR yolu 0032) ve hedef bit hızı seçeneği. Dosya adı bunları içersin (ör. `full_2800x1840_10pq_100m.h265`). Kolay içerik VT'nin hedef bit hızına ulaşmasını engelleyebilir: gren/gürültü düzeyi ayarlanabilir olsun ve **gerçekleşen Mbps** üretimde yazılsın; hedeften %15'ten fazla sapan klip açıkça işaretlensin. Varsayılan set: full 2800×1840 × {8, 10sdr, 10pq} @60 Mbps + 8 ve 10pq × {80, 100, 150} Mbps. İsteğe bağlı: 8-bit 60 Mbps `idr=60` (her 60 karede IDR).
- **Android probu:** yeni dosya adlarını tanısın (ad → boyut/biçim çözümleme), 10-bit çıkışta `ImageReader` biçimi uygun seçilsin (PRIVATE çalışmazsa açıkça `ERR` yaz, sessizce düşme). İstatistiklere **p99 ve maks** gecikme ile çıkışlar arası p99 eklensin; IDR'li klipte IDR karelerinin gecikmesi ayrıca raporlansın. Kullanılan çözücü adı ve profil (`Main10`, `Main10HDR10`) satırda görünsün.
- Probu orkestratör çalıştıracak (MateBridge kapalıyken, tek cihaz testi). Kartın Handoff'una T-248'deki gibi kopyala-yapıştır çalıştırma bloğu yaz: sınırsız (`image`) ve `pace=120` + `pace=60` koşuları, tüm klipler.
- Mac'te pencere açma, sanal ekran kurma; kısa VT kodlama serbest. adb/tablet yok.

## Kabul kriterleri

- [x] Klip üreteci yeni seçeneklerle derlenir ve varsayılan seti `~/.cache/matebridge-tools/data/decprobe/` altına üretir; her klip için gerçekleşen Mbps + AU sayısı doğrulanır; 10-bit kliplerde SPS'te `bit_depth_luma=10` ve doğru renk VUI'si (test ya da üretim sonu kontrolü).
- [x] Android probu `assembleDebug testDebugUnitTest` geçer; yeni JVM testleri ad çözümleme + p99/maks hesabı.
- [x] `./scripts/check.sh` geçer.
- [x] Handoff: çalıştırma bloğu ve sonuç yorumu rehberi (10-bit ≈ 8-bit mi; bit hızıyla gecikme kuyruğu nasıl büyür; hangi sonuç hangi kararı/sınırı değiştirir).

## Plan

1. Swift `DecProbeCore`: `ClipDepth` (8 / 10sdr / 10pq), `ClipVariant` (`DEPTH@MBPS[/idrN]`, varsayılan 10'luk set), dosya adı `<id>_<WxH>_<derinlik>_<N>m[_idrK].h265`, gerçekleşen Mbps + %15 sapma işareti, HDR10 SEI (MDCV/CLL) NAL'leri, küçük SPS ayrıştırıcı (profil, bit derinliği, VUI renk) + SEI tür okuyucu; testleri.
2. `decprobe-clips`: Main/Main10 profili, renk özellikleri, IDR aralığı, ayarlanabilir foto grenı + otomatik yeniden kodlama, üretim sonu doğrulama (AU/IRAP, SPS, SEI), çıktıda gerçekleşen Mbps.
3. Android: yeni ad çözümleme (`ClipFile`: derinlik/Mbps/IDR, eski adlar da), senaryo kimlikleri (`1xfull_10pq_100m`), p99 + maks gecikme, çıkışlar arası p99, IDR kare gecikmesi, `prof=` + çözücü adı (klip biçimine göre `findDecoderForFormat`), `imgfmt`/`colorkeys` extras (sessiz düşme yok), JVM testleri.
4. README + `./scripts/check.sh` + `assembleDebug testDebugUnitTest`, varsayılan seti üret, Handoff.

## Handoff

- **Commit:** `31d82f2` (uygulama), dal `task/T-249-decoder-probe-10bit` (main `1e1ca76` üzerine). Kart güncellemesi sonraki commit.
- **Dosyalar:** `probes/decoder-concurrency-probe/` (Swift: `ClipSpec.swift`, yeni `HevcSPS.swift`, `AnnexB.swift`, `ClipEncoder.swift`, `Scene.swift`, `main.swift`, testler; Android: `Scenario.kt`, `Stats.kt`, `AnnexB.kt`, `DecoderSession.kt`, `DecProbeActivity.kt`, testler; `README.md` T-249 bölümü), `probes/README.md` (satır), bu kart.
- **Doğrulama:** `./scripts/check.sh` ALL OK (Swift probu 10 test). Android `assembleDebug testDebugUnitTest` geçti (`RealClipTest` Mac'teki gerçek 14 klibi ayrıştırdı: her biri 600 AU, IRAP sayısı beklenen; yeni kliplerde IDR bayrakları doğru). APK: `probes/decoder-concurrency-probe/android/app/build/outputs/apk/debug/app-debug.apk`.
- **Klipler üretildi** (`~/.cache/matebridge-tools/data/decprobe/`, 600 kare, hepsi `OK`: `pictures=600`, SPS profil/derinlik/renk, 10pq için SEI 137+144 doğrulandı, hiçbiri OFF-TARGET): 

| Klip | Hedef | Gerçekleşen | IRAP | SPS |
|---|---|---|---|---|
| `full_2800x1840_8_60m` | 60 | 60,2 | 1 | Main, 8-bit, 709 |
| `…_10sdr_60m` | 60 | 60,1 | 1 | Main10, 10-bit, 709 |
| `…_10pq_60m` | 60 | 60,2 | 1 | Main10, 10-bit, 2020/PQ + MDCV/CLL |
| `…_8_80m` / `_8_100m` / `_8_150m` | 80/100/150 | 80,5 / 100,7 / 150,5 | 1 | Main, 8-bit |
| `…_10pq_80m` / `_100m` / `_150m` | 80/100/150 | 80,5 / 100,8 / 152,2 | 1 | Main10 PQ |
| `…_8_60m_idr60` | 60 | 61,1 | 10 | Main, IDR/60 kare |

  Gerçekleşen Mbps 120 fps hız kontrolüne göre (karelerin 120 fps'te geldiği varsayımıyla). Grain 6 (60 Mbps), 11 (80), 16 (100), 28 (150); yeniden kodlama gerekmedi. Eski `full/half/half_right/quarter_*.h265` dosyaları da duruyor (probda okunur).
- **Varsayımlar:** (1) Sahne 8-bit sRGB çizilip VT'de 10-bit'e dönüştürülüyor; 10-bit klipler "10-bit akış biçimi", gerçek 10-bit hassasiyetli içerik değil (çözücü yükü için sorun değil, bantlanma incelemesi için uygun değil; bantlanma fikri için ayrı iş). (2) VT HDR10 SEI'lerini örnek verisine koymuyor; yazıcı MDCV/CLL prefix SEI'lerini her IDR önüne ekliyor (1000 nit P3-D65, MaxCLL 1000, MaxFALL 400, hdr-probe ile aynı). (3) 10-bit için `KEY_PROFILE` + renk anahtarları (BT.2020/ST2084 ya da 709) varsayılan açık (`--es colorkeys none` ile kapanır); çözücü klip biçimine göre `findDecoderForFormat` ile seçilir (10-bit için profil istenir), seçim `codec=` ve `prof=` ile satırda. (4) `image` çıkışı ImageReader `PRIVATE`; kabul etmezse `ERR(configure:…)` (sessiz düşme yok), `--es imgfmt p010|rgba1010102|rgba8888` ile denenir. (5) `lat` taşkın modda giriş kuyruğu beklemesini içerir; gecikme için `pace=` koşuları esas.
- **Test edilmeyen:** tabletteki her şey (adb yok): 10-bit çıkışta PRIVATE ImageReader'ın çalışıp çalışmadığı, Main10HDR10 çözücü seçimi, `KEY_PROFILE`/renk anahtarlarının configure'u bozup bozmadığı, 10 klibin (~640 MB) push'u. Mac'te klip çözümü denenmedi (yalnız AU/IRAP/SPS/SEI doğrulaması).

### Orkestratör: tablette (MateBridge istemcisi kapalı, ekran açık, tek cihaz testi, 3 koşu x ~2 dk)

Kopyala-yapıştır bloğu `probes/decoder-concurrency-probe/README.md` "T-249 / Tablette" bölümünde; aynısı:

```bash
ADB=~/Library/Android/sdk/platform-tools/adb
D=~/.cache/matebridge-tools/data/decprobe
P=/sdcard/Android/data/dev.matebridge.decprobe/files
SC=1xfull_8_60m,1xfull_10sdr_60m,1xfull_10pq_60m,1xfull_8_80m,1xfull_8_100m,1xfull_8_150m,1xfull_10pq_80m,1xfull_10pq_100m,1xfull_10pq_150m,1xfull_8_60m_idr60
$ADB shell am force-stop dev.matebridge.client
$ADB install -r probes/decoder-concurrency-probe/android/app/build/outputs/apk/debug/app-debug.apk
$ADB shell mkdir -p $P
for f in $(ls $D | grep -E '^full_2800x1840_(8|10sdr|10pq)_[0-9]+m(_idr[0-9]+)?\.h265$'); do $ADB push $D/$f $P/; done
# 1) sınırsız (kapasite)
$ADB logcat -c
$ADB shell am start -n dev.matebridge.decprobe/.DecProbeActivity --es scenarios $SC --es outputs image
sleep 125
$ADB logcat -d -s DECPROBE:I | grep -E "DECPROBE (scen|info|done|aborted)"
# 2) pace=120
$ADB shell am force-stop dev.matebridge.decprobe; $ADB logcat -c
$ADB shell am start -n dev.matebridge.decprobe/.DecProbeActivity --es scenarios $SC --es outputs image --es pace 120
sleep 125
$ADB logcat -d -s DECPROBE:I | grep -E "DECPROBE (scen|done|aborted)"
# 3) pace=60
$ADB shell am force-stop dev.matebridge.decprobe; $ADB logcat -c
$ADB shell am start -n dev.matebridge.decprobe/.DecProbeActivity --es scenarios $SC --es outputs image --es pace 60
sleep 125
$ADB logcat -d -s DECPROBE:I | grep -E "DECPROBE (scen|done|aborted)"
$ADB shell am force-stop dev.matebridge.decprobe
```

Kontrol: `info clip … units=600`; çözücü adı ve `profiles=[…]` (Main10HDR10 var mı); her `scen=` satırında `ok=1` ve `img` ≈ kare sayısı; `DECPROBE done`. 10-bit satırda `ERR(configure:…)` çıkarsa yalnız 10-bit senaryoları (`1xfull_10sdr_60m,1xfull_10pq_60m,1xfull_10pq_100m`) `--es imgfmt p010` ile, sonra `--es colorkeys none` ile tekrarla.

### Sonuç yorumu rehberi

- **10-bit ≈ 8-bit mi?** `full_8_60m` / `full_10sdr_60m` / `full_10pq_60m` karşılaştır (pace=0'da `total_fps`, pace=120'de `lat` p50/p95/p99/max ve `miss`). Fark <%5 ve `miss0` ise 10-bit çözme maliyeti yok: 0032'deki "HDR yalnız Oyun 60" çekincesi çözücü açısından kalkar (sınır kodlayıcı/Wi-Fi/yüzey tarafında kalır; `10sdr` bantlanma fikri çözücüye engel değil). `10pq` yavaşsa ama `10sdr` aynıysa darboğaz HDR yolu/renk işleme, 10-bit değil. 10-bit satırda `ERR` varsa HDR/10-bit akış bu yüzeyle çözülemiyor (imgfmt denemesi sonucu kararı belirler).
- **Bit hızı:** `8_60m → 8_80m → 8_100m → 8_150m` ve 10pq karşılığında pace=120 `lat` p99/maks ve `gap` p99'un nasıl büyüdüğüne bak. p50 sabit, p99/maks büyüyorsa kuyruk çözücü giriş bant genişliğinden/IDR'den gelir. Kuyruk 100 Mbps'e kadar düzse host 80 Mbps tavanı ve Oyun/Çizim Otomatik 60 Mbps çözücüden kaynaklı değil, yükseltilebilir (Wi-Fi/kodlayıcı ayrı sınır); 150 Mbps'te `miss>0` ya da p99>16 ms ise pratik üst sınır orada. T-085'teki p99 40 ms bulgusu burada yoksa (çözücü p99 ≈ p50) o kuyruk çözücüden değil ağ/kodlayıcı/yüzey tarafından gelmiştir.
- **IDR:** `full_8_60m_idr60` satırındaki `idrN:p50/maks` ile `lat` p50'yi karşılaştır; IDR karesinin çözme gecikmesi normal kareden ≤1–2 ms fazlaysa kurtarma IDR'si çözücüde pahalı değil (kayıp kurtarma maliyeti ağ/kodlayıcıda).
- **pace=60:** Oyun/Çizim 60 fps tempoda aynı klipler; `miss0` ve p99 küçükse bu bit hızları 60 fps'te rahat.

## Open questions

- `scripts/check.sh` yalnız Swift probunu derler/test eder; Android probu elle derlenir (T-248 ile aynı, bilinçli).
- Gerçek 10-bit hassasiyetli içerik (bantlanma/gradyan testi) bu kartın kapsamında değil.
