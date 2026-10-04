# hdr-probe (T-226)

HDR zincirinin yalnız deneyle cevaplanabilen halkaları için iki küçük prob. Ürün kodu değildir. Rapor: `docs/research/2026-10-04-hdr-feasibility.md`.

- `hdr-probe` (Swift, bu klasör): sanal ekranın HDR bildirip bildirmediği, SCK HDR yakalama, VideoToolbox Main10 PQ/HLG kodlama süresi ve Android probu için test klibi.
- `android/` (Kotlin): HiSilicon decoder'ın Main10 PQ/HLG klibini `SurfaceView`'a nasıl verdiği ve HarmonyOS 4.3'ün ekranı HDR moduna alıp almadığı.

`scripts/check.sh` yalnız Swift paketini derler ve test eder (`probes/*/Package.swift`). Android probu alt klasörde olduğu için check.sh'a girmez; elle derlenir (aşağıda).

## Ne neye dokunur

| Komut | Dokunduğu şey | Kim çalıştırır |
|---|---|---|
| `hdr-probe inspect` | Hiçbir şey: runtime seçici listesi, `NSScreen` EDR değerleri, VT yetenek sorgusu (oturum yok), SCK preset nesneleri | Herkes, her an |
| `hdr-probe vd ...` | **Sanal ekran kurar** (vendor 0x4D42, product 0x0226; MateBridge'inkiyle çakışmaz), isteğe bağlı SCK yakalama (Ekran Kaydı izni), sonra ekranı kaldırır. Pencere açmaz, Dock simgesi yok. | Orkestratör, **kullanıcı onayıyla**, tek seferde bir cihaz testi |
| `hdr-probe encode ...` | Donanım HEVC kodlayıcısı (tek kodlayıcı). Ekran/yakalama yok. | Orkestratör, **MateBridge akışı kapalıyken** |
| Android probu | Tablete APK kurar ve açar | Orkestratör, **kullanıcı onayıyla** |

## Derleme

```bash
cd probes/hdr-probe
swift build -c release            # .build/release/hdr-probe
swift test

cd android
JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
ANDROID_HOME=~/Library/Android/sdk ./gradlew assembleDebug testDebugUnitTest
# APK: android/app/build/outputs/apk/debug/app-debug.apk
```

## Adım 1 — sanal ekran HDR oluyor mu? (Mac, onaylı)

Ekran kurulup kaldırılırken Mac'teki pencere düzeni kısa süre oynayabilir. MateBridge açık kalabilir: prob ayrı bir ekran kurar. Her adımda yalnız tek bir test çalışır.

```bash
.build/release/hdr-probe inspect                         # önce: referans satırlar
.build/release/hdr-probe vd --sweep                      # transferFunction: yok, 0, 1, 2, 3, 4 (her biri ~6 s)
.build/release/hdr-probe vd --tf 1 --reference           # Sidecar'ın kullandığı birleşim (isReference + tf=1)
.build/release/hdr-probe vd --tf 1 --p3                  # P3 primerleriyle
```

Okunacak: her ekran için `maxPotentialEDR` (> 1 = macOS ekranı HDR/EDR sayıyor; oyunlar buna bakar), `cgColorSpace ... hdr=`, mod listesi. `applySettings` reddi (`settingsRejected`) da bir sonuçtur.

## Adım 2 — SCK HDR yakalama (Mac, onaylı; Terminal'in Ekran Kaydı izni gerekir)

```bash
.build/release/hdr-probe vd --tf 1 --capture recording --capture-seconds 3
.build/release/hdr-probe vd --tf 1 --capture canonical --capture-seconds 3
.build/release/hdr-probe vd --tf 1 --capture sdr --capture-seconds 3   # bugünkü yapılandırma, HDR ekranda
.build/release/hdr-probe vd --tf 0 --capture recording                  # karşılaştırma: SDR ekranda HDR yakalama
```

Okunacak: `frames=` (60 fps'e yakın mı), kare biçimi (`x420`/`xf44`), renk etiketleri, `luma max / p99 / p50` ve PQ'da nit karşılığı. Boş masaüstünde en parlak değer, SDR beyazının yakalamada kaç nit'e düştüğünü verir (beklenti 100–203 nit). HDR içerik görmek için `--hold 60` ekleyip o sürede bir HDR videoyu ya da oyunu prob ekranına taşımak gerekir. Bu ekran tablette görünmez; kullanıcıyla birlikte planlanmalıdır, aksi halde yalnız SDR beyazı ölçülür.

## Adım 3 — Main10 HDR kodlama süresi (Mac, akış kapalıyken)

```bash
.build/release/hdr-probe encode --path fast --transfer pq --fps 120 --seconds 5
.build/release/hdr-probe encode --path fast --transfer pq --fps 60 --seconds 5
.build/release/hdr-probe encode --path llrc --transfer pq --fps 60 --seconds 5
.build/release/hdr-probe encode --path fast --transfer pq --fps 60 --seconds 10 --out /tmp/hdr.mp4
.build/release/hdr-probe encode --path fast --transfer hlg --fps 60 --seconds 10 --out /tmp/hdr-hlg.mp4
```

Karşılaştırma tabanı T-047 (8-bit, `nolat-rtoff`: 120 fps'te p50 5.8 ms / p99 ~10 ms). `set ... -> error` satırları desteklenmeyen anahtarı gösterir. `format ...` satırları kodlanmış akışın renk/HDR uzantılarını gösterir.

## Adım 4 — tablette çözme ve HDR gösterim (onaylı, tek seferde bir cihaz testi)

MateBridge istemcisi bu sırada kapalı olmalı (decoder ve ekran paylaşılmasın).

```bash
ADB=~/Library/Android/sdk/platform-tools/adb
$ADB install -r android/app/build/outputs/apk/debug/app-debug.apk
$ADB shell mkdir -p /sdcard/Android/data/dev.matebridge.hdrprobe/files
$ADB push /tmp/hdr.mp4 /sdcard/Android/data/dev.matebridge.hdrprobe/files/hdr.mp4
$ADB push /tmp/hdr-hlg.mp4 /sdcard/Android/data/dev.matebridge.hdrprobe/files/hdr-hlg.mp4
$ADB logcat -c
$ADB shell am start -n dev.matebridge.hdrprobe/.HdrProbeActivity                       # PQ, KEY_HDR_STATIC_INFO ile
sleep 5
$ADB shell dumpsys SurfaceFlinger | grep -E "mIsHdrLayerPresent|HWC Support|BT2020|P010|hdrprobe"
$ADB shell dumpsys display | grep -E "mIsHdrLayerPresent|ColorMode"
$ADB logcat -d -s MBHDR
$ADB shell am force-stop dev.matebridge.hdrprobe
# Varyantlar:
$ADB shell am start -n dev.matebridge.hdrprobe/.HdrProbeActivity --es clip hdr-hlg.mp4
$ADB shell am start -n dev.matebridge.hdrprobe/.HdrProbeActivity --ez static_info false
$ADB shell am start -n dev.matebridge.hdrprobe/.HdrProbeActivity --es tags explicit
# Bitince:
$ADB shell am force-stop dev.matebridge.hdrprobe
$ADB uninstall dev.matebridge.hdrprobe
```

Okunacak:
- `MBHDR` günlüğü: `findDecoderForFormat`, `advertises Main10HDR10`, `output format: ... standard= transfer= range= hdrStaticInfo=`, hata satırları.
- SurfaceFlinger: video katmanının dataspace'i (`BT2020_PQ` / `BT2020_HLG` mı, yoksa `SRGB`/`UNKNOWN` mı), biçimi (`P010` mu `NV12` mi), `mIsHdrLayerPresent=true` mu, katman `DEVICE` (HWC) mı `CLIENT` (GPU) mı.
- Göz: klipteki 203 nit yamasıyla sağ üstteki SDR beyaz yama yan yana. 1000 nit yaması belirgin daha parlak mı? Rampada bantlaşma var mı? HDR açılınca arayüz (SDR) karardı mı ya da parladı mı?
