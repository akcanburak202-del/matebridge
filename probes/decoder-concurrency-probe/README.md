# decoder-concurrency-probe (T-248)

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
# seçenekler: --frames 600 --fps 120 --full-kbps 60000 --clips full,half,half_right,quarter --out-dir DIR

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
