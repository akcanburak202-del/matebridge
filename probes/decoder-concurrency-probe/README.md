# decoder-concurrency-probe (T-248, T-249)

> T-249 (10-bit ve yüksek bit hızı) için en alttaki "T-249" bölümüne bakın. Aşağıdaki T-248 anlatımı klip adlarını eski biçimde (`full_2800x1840.h265`) gösterir; üretici artık varsayılan olarak T-249 setini yapar (`--variants 8@60 --clips full,half,half_right,quarter` ile T-248 setinin 8-bit karşılığı, adlar `<id>_<WxH>_8_<N>m.h265`; eski adlı dosyalar probda hâlâ okunur).

Soru: tabletin HEVC çözücüsü (`OMX.hisi.video.decoder.hevc`) eş zamanlı oturumlarla toplam hızı artırıyor mu (çok çekirdek), yoksa oturumlar aynı hattı mı paylaşıyor? Bu, görüntüyü iki yarıya bölüp iki çözücüde çözme fikrinin (çözücü sınırını aşmak) ön koşulu. Ürün kodu değildir.

- `decprobe-clips` (Swift, bu klasör): gerçekçi içerikli 8-bit HEVC klipler üretir (tüm kareyi kaplayan kayan prosedürel fotoğraf + her yarıda farklı hızda kayan yazı paneli). MateBridge hızlı profiline yakın: donanım HEVC Main, LLRC yok, RealTime=false, B-kare yok, PrioritizeSpeed, 120 fps hız kontrolü, tam kare 60 Mbps (kırpıntılar alanla orantılı), DataRateLimits 2×, tek IDR (kare 0). 600 kare, Annex-B (IDR önünde VPS/SPS/PPS).
- `android/` (Kotlin, `dev.matebridge.decprobe`): N eş zamanlı `MediaCodec` (her biri kendi `HandlerThread`'inde, asenkron mod, klibi IDR'den döngüleyerek) en hızlı şekilde çözer ve senaryo başına tek bir `DECPROBE` satırı yazar.

| Dosya | Boyut | Bit hızı | İçerik |
|---|---|---|---|
| `full_2800x1840.h265` | 2800×1840 | 60 Mbps | tam sahne |
| `half_1400x1840.h265` | 1400×1840 | 30 Mbps | sol yarı |
| `half_right_1400x1840.h265` | 1400×1840 | 30 Mbps | sağ yarı |
| `quarter_1400x920.h265` | 1400×920 | 15 Mbps | sol üst çeyrek |

Yarım ve çeyrek klipler tam klibin aynı karelerinin kırpıntısıdır, yani `2xhalf` (sol + sağ) gerçek bölme senaryosunun aynısıdır.

`scripts/check.sh` yalnız Swift paketini derler ve test eder. Android probu alt klasörde olduğu için check.sh'a girmez; elle derlenir.

## Ne neye dokunur

| Komut | Dokunduğu şey | Kim çalıştırır |
|---|---|---|
| `decprobe-clips` | Donanım HEVC kodlayıcısı (bir seferde tek oturum, klip başına 1–4 s). Ekran, yakalama, pencere yok. | Herkes; tercihen MateBridge akışı kapalıyken |
| `decprobe-clips --preview N` | Hiçbir şey: kare N'yi PNG olarak yazar (içeriğe bakmak için) | Herkes |
| Android probu | Tablete APK kurar, açılınca ~2 dk çözücü testi yapar | Orkestratör, MateBridge istemcisi **kapalıyken**, tek seferde bir cihaz testi |

## Derleme ve klipler (Mac)

```bash
cd probes/decoder-concurrency-probe
swift build -c release
swift test
.build/release/decprobe-clips              # -> ~/.cache/matebridge-tools/data/decprobe/*.h265
# seçenekler: --frames 600 --fps 120 --clips full --variants LIST --grain N --out-dir DIR (ayrıntı: T-249 bölümü)

cd android
JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
ANDROID_HOME=~/Library/Android/sdk ./gradlew assembleDebug testDebugUnitTest
# APK: android/app/build/outputs/apk/debug/app-debug.apk
```

Her klip satırında `OK` olmalı: `pictures=600 irap=1 errors=0` ve hedefe yakın Mbps.

## Tablette çalıştırma

MateBridge istemcisi kapalı olmalı (çözücü paylaşılmasın). Ekran açık ve kilitsiz olmalı. Prob açılınca hemen başlar, ön planda kalmalıdır (`onPause` her şeyi durdurur).

```bash
ADB=~/Library/Android/sdk/platform-tools/adb
D=~/.cache/matebridge-tools/data/decprobe
P=/sdcard/Android/data/dev.matebridge.decprobe/files
$ADB shell am force-stop dev.matebridge.client
$ADB install -r probes/decoder-concurrency-probe/android/app/build/outputs/apk/debug/app-debug.apk
$ADB shell mkdir -p $P
for f in full_2800x1840 half_1400x1840 half_right_1400x1840 quarter_1400x920; do $ADB push $D/$f.h265 $P/; done
$ADB logcat -c

# 1) Ana koşu: 1xfull, 2xfull, 1xhalf, 2xhalf, 3xhalf × image, buffer; 8 s (1 s ısınma) -> ~2 dk
$ADB shell am start -n dev.matebridge.decprobe/.DecProbeActivity
sleep 125
$ADB logcat -d -s DECPROBE:I | grep -E "DECPROBE (scen|info|done|aborted)"

# 2) Gecikme: 120 fps tempolu besleme (kare başına gerçek çözme süresi; tam vs yarılar)
$ADB shell am force-stop dev.matebridge.decprobe
$ADB logcat -c
$ADB shell am start -n dev.matebridge.decprobe/.DecProbeActivity --es pace 120 --es outputs image \
    --es scenarios 1xfull,1xhalf,2xhalf
sleep 40
$ADB logcat -d -s DECPROBE:I | grep -E "DECPROBE (scen|done|aborted)"

# Sonuç dosyası (son koşu) ve kapatma
$ADB shell cat $P/decprobe-results.txt
$ADB shell am force-stop dev.matebridge.decprobe
```

Extras (hepsi `--es`, metin): `scenarios` (varsayılan `1xfull,2xfull,1xhalf,2xhalf,3xhalf`; `NxCLIP`, `half` sol/sağ dönüşümlü; açık liste `full+quarter`), `outputs` (`image,buffer`), `seconds` (8), `warmup` (1), `pace` (0 = olabildiğince hızlı; 120 = 1/120 s'de bir kare), `prio` (`0`, `1`, `none`), `oprate` (`max` = Short.MAX, sayı, `none`), `codec` (çözücü adı; varsayılan HEVC 2800×1840 için `findDecoderForFormat`). Örnek: `--es scenarios 1xquarter,4xquarter`, `--es prio none --es oprate none` (kaynak sınırına takılırsa).

## Okuma

Senaryo başına bir satır:

```
DECPROBE scen=2xhalf out=image pace=0 n=2 ok=2 win=7.0s total_fps=… min_fps=… total_mpxs=… codec=… s0=half:…fps,latP50/P95,gapP50/P95,imgN s1=half_right:… thermal=0
```

- `total_fps` oturumların kare/s toplamı; `total_mpxs` toplam Mpx/s (karşılaştırmanın ana sayısı); `min_fps` en yavaş oturum = bölünmüş ekranda tam ekran kare hızı.
- `lat` kuyruğa koyma → çıkış (ms, p50/p95). Taşkın modunda (`pace=0`) giriş kuyruğundaki bekleme dahildir; saf çözme süresi için `pace=120` koşusuna bakın. `gap` ardışık çıkışlar arası süre (taşkında ≈ kare başına çözme maliyeti).
- `img` ImageReader'a ulaşan kare (yalnız `image`); `miss` tempolu koşuda çözücünün geride kaldığı tik sayısı.
- `ERR(configure:…)` çözücü oturumu açılamadı (kaynak sınırı da bir sonuçtur). `thermal` = `PowerManager.currentThermalStatus` (0 = yok).
- `info` satırları: klip AU sayısı (600 olmalı), çözücü adı, `max_instances`, performans noktaları, boyut başına `achievable` aralığı, ilk çıkış biçimi.

Yorum:

- `2xhalf total_mpxs ≈ 2 × 1xhalf total_mpxs` (ve `2xhalf min_fps ≈ 1xhalf fps`) → oturumlar paralel çekirdeklerde; ekranı ikiye bölmek kare hızını/gecikmeyi iyileştirebilir.
- `2xhalf total_mpxs ≈ 1xhalf total_mpxs` (her oturum yarı hızda) → tek hat zaman paylaşımı; bölme yalnız kare başına sabit maliyeti (~3,7 ms) iki kez öder, kazanç yok.
- Arası (ör. 1,3–1,6×) → kısmi paralellik (ör. entropi çözme ayrı, yeniden yapılandırma ortak). `2xfull` aynı soruyu tam boyutta, `3xhalf` doygunluk noktasını gösterir.
- `image` ile `buffer` farkı yüzey/kopya maliyetidir; ürün yüzeye çizdiği için `image` sayıları esas alınır.

## T-249: 10-bit (SDR / HDR PQ) ve yüksek bit hızı

Sorular: (1) HEVC Main10 (BT.709 10-bit ve HDR10 PQ/BT.2020) çözme kapasitesi ve gecikmesi 8-bit ile aynı mı? (2) 60 / 80 / 100 / 150 Mbps'te kapasite ve gecikme kuyruğu (p99, maks) nasıl? (3) isteğe bağlı: IDR karesinin çözme gecikmesi.

### Klipler (Mac)

```bash
cd probes/decoder-concurrency-probe
swift build -c release
.build/release/decprobe-clips                 # varsayılan set (10 klip, ~40 s) -> ~/.cache/matebridge-tools/data/decprobe/
.build/release/decprobe-clips --variants 10pq@100,8@60/idr30 --clips full,half   # özel
```

- `--variants` = virgüllü `DERINLIK@MBPS[/idrN]`; derinlik `8` (Main, BT.709), `10sdr` (Main10, BT.709), `10pq` (Main10, BT.2020 / ST 2084 PQ, MDCV + CLL SEI); MBPS tam kare Mbps'i (kırpıntılar alanla orantılı); `/idrN` her N karede IDR (varsayılan tek IDR). `--clips` kırpıntılar (varsayılan yalnız `full`). Varsayılan set: `8@60,10sdr@60,10pq@60,8@80,8@100,8@150,10pq@80,10pq@100,10pq@150,8@60/idr60`.
- Dosya adı: `<id>_<WxH>_<derinlik>_<N>m[_idr<K>].h265`, ör. `full_2800x1840_10pq_100m.h265`. Probda senaryo kimliği boyutsuz addır: `full_10pq_100m`, `full_8_60m_idr60`.
- Hedef bit hızı: VT'nin hedefe ulaşması içeriğe bağlı; foto gren genliği (`--grain N`, varsayılan 6 + (Mbps−60)/4) ve tolerans dışıysa otomatik yeniden kodlama (en çok 3 deneme; `--no-retry` kapatır). Üretim sonunda her klip için **gerçekleşen Mbps** (120 fps hız kontrolüne göre) ve hedeften sapma yazılır; %15'ten fazla sapan klip `OFF-TARGET` ile işaretlenir.
- Üretim sonu doğrulama (satırda `OK`/`FAIL`): AU sayısı = kare sayısı, IRAP sayısı (tek IDR ya da ceil(kare/N)), SPS'ten `general_profile_idc` (1 Main / 2 Main10), `bit_depth_luma/chroma`, boyut, VUI renk (709: 1/1/1, PQ: 9/16/9), 10pq için MDCV (137) ve CLL (144) SEI. VT bu SEI'leri örnek verisine koymaz (yalnız biçim tanımında); yazıcı IDR öncesine kendisi ekler.
- Not: sahne 8-bit sRGB olarak çizilir ve VT 10-bit'e dönüştürür; yani 10-bit klip 10-bit hassasiyetli içerik değil, 10-bit akış biçimidir (bit/kare hedefi tutturulur; çözücü yükü için fark yaratmaz, bantlanma incelemesi için uygun değildir).

### Tablette (orkestratör; MateBridge istemcisi kapalı, ekran açık, tek cihaz testi)

```bash
ADB=~/Library/Android/sdk/platform-tools/adb
D=~/.cache/matebridge-tools/data/decprobe
P=/sdcard/Android/data/dev.matebridge.decprobe/files
SC=1xfull_8_60m,1xfull_10sdr_60m,1xfull_10pq_60m,1xfull_8_80m,1xfull_8_100m,1xfull_8_150m,1xfull_10pq_80m,1xfull_10pq_100m,1xfull_10pq_150m,1xfull_8_60m_idr60
$ADB shell am force-stop dev.matebridge.client
$ADB install -r probes/decoder-concurrency-probe/android/app/build/outputs/apk/debug/app-debug.apk
$ADB shell mkdir -p $P
for f in $(ls $D | grep -E '^full_2800x1840_(8|10sdr|10pq)_[0-9]+m(_idr[0-9]+)?\.h265$'); do $ADB push $D/$f $P/; done
# 1) sınırsız (kapasite) + gecikme kuyruğu; ~110 s
$ADB logcat -c
$ADB shell am start -n dev.matebridge.decprobe/.DecProbeActivity --es scenarios $SC --es outputs image
sleep 125
$ADB logcat -d -s DECPROBE:I | grep -E "DECPROBE (scen|info|done|aborted)"
# 2) 120 fps tempolu besleme (kare başına gerçek çözme süresi ve kuyruk)
$ADB shell am force-stop dev.matebridge.decprobe; $ADB logcat -c
$ADB shell am start -n dev.matebridge.decprobe/.DecProbeActivity --es scenarios $SC --es outputs image --es pace 120
sleep 125
$ADB logcat -d -s DECPROBE:I | grep -E "DECPROBE (scen|done|aborted)"
# 3) 60 fps tempolu besleme (Oyun/Çizim 60 fps karşılığı)
$ADB shell am force-stop dev.matebridge.decprobe; $ADB logcat -c
$ADB shell am start -n dev.matebridge.decprobe/.DecProbeActivity --es scenarios $SC --es outputs image --es pace 60
sleep 125
$ADB logcat -d -s DECPROBE:I | grep -E "DECPROBE (scen|done|aborted)"
$ADB shell am force-stop dev.matebridge.decprobe
```

`ERR(configure:…)` 10-bit satırlarında çıkarsa (PRIVATE biçimi 10-bit çıkışı kabul etmiyor olabilir): `--es imgfmt p010` (ya da `rgba1010102`) ile yalnız 10-bit senaryolarını tekrarla; hâlâ ERR ise `--es colorkeys none`. Sessiz düşme yoktur, hata satırda görünür. Yalnız bir kopya (`outputs buffer`) için `--es outputs buffer`.

### Okuma

Satır biçimi: `DECPROBE scen=… out=… pace=… n=… ok=… win=… total_fps=… min_fps=… total_mpxs=… codec=<çözücü> prof=<Main|Main10|Main10HDR10> s0=<klip>:<fps>fps,lat<p50>/<p95>/<p99>/<maks>,gap<p50>/<p95>/<p99>[,idr<N>:<p50>/<maks>],img…[,miss…] thermal=…`

- `lat` kuyruğa koyma → çıkış (ms). **Taşkın (`pace=0`) modunda giriş kuyruğundaki bekleme dahildir**: kapasite için `total_fps`/`total_mpxs`, saf çözme süresi için `pace=` koşularına bakın. `gap` çıkışlar arası süre (p99 = tıkanma kuyruğu). `idrN` penceredeki N IDR karesinin gecikmesi (yalnız IDR'li klipte anlamlı; tek IDR'li klipte N ≈ döngü sayısı).
- `miss` tempolu koşuda çözücünün geride kaldığı tik sayısı: sıfırdan büyükse o bit hızı/biçim o tempoyu **taşıyamıyor**.
- `info` satırları: çözücü, `profiles=[…]` (Main10HDR10 listede mi), `does not advertise profile …` uyarısı, klip AU sayısı (600).
