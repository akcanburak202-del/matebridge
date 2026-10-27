---
id: T-384
title: Probe (Xiaomi Pad Mini, MTK) — tam renk ham GPU okuması neden tutmuyor; çalışan bir yol var mı
status: review
phase: 7
owner: android-client-dev
depends_on: [T-254, T-259]
decisions: [0034]
files:
  - probes/yuv444-probe/android/
  - backlog/tasks/T-384-probe-full-chroma-mtk.md
---

## Amaç

İkinci tablet Xiaomi Pad Mini 2025 (25079RPDCG, HyperOS 3 / Android 16, MediaTek Dimensity 9400 / Mali-G925, adb `-s 192.168.1.108:5555`) üzerinde "Tam renk" (0034) öz testi başarısız. Daily 822db87f, 2026-10-27 23:43:

```
full_chroma_selftest_detail raw_compare ok=1 exact=0 flip=0 ahb_fmt=0x7f000010 ahb=256x144 y_mis=36785/36864 y_max=237 cb_mis=9197/9216 cb_max=243 cr_mis=9190/9216 cr_max=242 glerr=0x0 second_output=1
```

Hemen her örnek farklı: küçük bir sapma değil, ham okuma yolu (`GL_EXT_YUV_target`, `__samplerExternal2DY2YEXT`) bu tamponda anlamsız değer veriyor ya da CPU okuması başka bir düzen görüyor. `ahb_fmt=0x7f000010` satıcıya özel bir biçim (MTK). Uzantı SurfaceFlinger GLES listesinde var. Hedef: çalışan bir yapılandırma var mı, yoksa bu cihazda Tam renk kapalı mı kalmalı. Uygulama kodu değişmez; sonuç karar ve gerekirse ayrı bir uygulama kartıdır.

## Kabul

1. Probe (`probes/yuv444-probe/android`, mevcut T2 yolu) Xiaomi'de çalışır ve her denemede tek satır `Y444PROBE` sonuç yazar: çözücü adı, ImageReader biçimi/usage, `ahb_fmt`, Y/Cb/Cr mismatch sayısı ve max fark, ayrıca GPU ve CPU'dan birkaç örnek değer (ör. ilk 8 Y ve 4 Cb/Cr, ve bir orta satır) — sorunun türü görülsün (sıfır mı, RGB mi, kaymış/döşemeli mi, ters kanal mı).
2. Denenecek değişkenler (her biri ayrı satır; açılamayan "unsupported" yazar):
   - Çözücü: `c2.mtk.hevc.decoder`, `c2.mtk.hevc.decoder.lowlatency` (varsa), `c2.android.hevc.decoder` (yazılım; standart düzen → GL yolunun kendisini sınar).
   - ImageReader: YUV_420_888 + (GPU_SAMPLED | CPU_READ_OFTEN) [bugünkü], PRIVATE + GPU_SAMPLED (CPU okuması yoksa karşılaştırma için yazılım çözücünün CPU çıktısı referans alınır), `HardwareBuffer.YCBCR_420_888` usage varyantları.
   - Okuma: `__samplerExternal2DY2YEXT` ham okuma; karşılaştırma için normal `samplerExternalOES` (RGB'ye çevirili) çıktısı — ham yol bozuk ama dönüşümlü yol doğruysa not et.
   - MediaFormat `color-format` (ör. `COLOR_FormatYUV420Flexible`) ve varsa MTK satıcı anahtarları (UFO/sıkıştırmayı kapatan bir parametre `MediaCodecInfo`/`getSupportedVendorParameters` listesinde varsa).
3. Sonuç tablosu ve yorum Handoff'ta: hangi kombinasyon bit-tam (varsa), ve uygulamaya taşımanın önerisi (ör. öz testi + ana yolu şu ImageReader/çözücü ile kur). Hiçbiri tutmuyorsa "bu cihazda tam renk yok" + kısa gerekçe.
4. Yalnız Xiaomi'ye (`-s 192.168.1.108:5555`) kurulur; MatePad'e (192.168.1.106) ve MateBridge uygulamasının verisine dokunulmaz. `adb kill-server` YOK. Mac'te pencere açılmaz. Probe kurulumu sırasında MateBridge kapalı olmalı (çözücü çekişmesi): başlamadan `am force-stop dev.matebridge.client`. Bitince probe paketi kaldırılır.
5. Probe `./scripts/check.sh` kapsamında değilse elle derleme komutu Handoff'ta.

## Plan

1. Probe'a yeni test `t5` (matris): `MatrixTest.kt`. Klip: istemcinin gomulu 256x144 intra karesi (`files/clip256.h265`, Mac'te base64'ten uretilip adb push) ve istege bagli buyuk klip. Referans: `c2.android.hevc.decoder` -> YUV_420_888 CPU planlari (HEVC cozumu bit-tam, referans budur).
2. Her kombinasyon (cozucu x ImageReader {YUV_420_888 GPU|CPU, PRIVATE GPU, YUV + YCBCR usage varyanti} x MediaFormat {varsayilan, color-format Flexible}): tek `Y444PROBE t5` satiri: cozucu, reader biçimi/usage, ahb_fmt, CPU-vs-ref ve GPU(ham)-vs-ref Y/Cb/Cr mismatch+max, ilk 8 Y / 4 Cb / 4 Cr ve orta satir ornekleri (ref, CPU, GPU), `samplerExternalOES` (donusumlu) ciktisinin referanstan beklenen BT.601/709 limited RGB'ye farki.
3. Native: `gpuRender(hwb,w,h,mode,half)` (ham/OES, tam/yari cozunurluk, RGBA geri) eklenir; karsilastirma Kotlin'de.
4. MTK satici parametreleri `MediaCodec.getSupportedVendorParameters()` ile listelenir (bilgi satiri).
5. Derle (gradle assembleDebug), Xiaomi'ye kur (MateBridge force-stop), calistir, sonuc Handoff'a, paketi kaldir.

## Handoff

Branch `task/T-384-probe-mtk-full-chroma` (SHA: son commit "T-384: t5 matrix probe + results").

**Sonuc: GPU ham okuma (`__samplerExternal2DY2YEXT`) Xiaomi/MTK'de BIT-TAM. Hata GPU yolunda degil, CPU REFERANSINDA: oz test MTK'nin varsayilan cikis tamponunu (`ahb_fmt=0x7f000010`, satici ozel duzen, CPU'dan okununca ref ile eslesmiyor) `Image.getPlanes()` ile okuyup GPU ile karsilastiriyor.** Referans olarak yazilim cozucu (`c2.android.hevc.decoder`, YV12 0x32315659) CPU ciktisi alindi (HEVC cozumu bit-tam); MTK GPU Y/Cb/Cr'si ona gore 0 mismatch.

Dosyalar: `probes/yuv444-probe/android/app/src/main/kotlin/dev/matebridge/yuv444probe/{MatrixTest.kt (yeni), Plan.kt, ProbeRunner.kt, Native.kt}`, `.../cpp/y444native.cpp` (`gpuRender`, `gpuInfo`, rawInit'te OES programi), bu kart.

Derleme/calistirma (check.sh bu probeyi kapsamiyor): `cd probes/yuv444-probe/android && ANDROID_HOME=~/Library/Android/sdk JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" ./gradlew assembleDebug` (sonra `./gradlew --stop`). Klipler `files/` altina: `clip256.h265` (istemcinin gomulu 256x144 karesi, `FullChromaSelfTestClip` base64'ten uretildi, 5122 bayt) ve `big.h265` (= main_1848x1214_60.h265, yalniz ilk IDR kullanilir). `am start -n dev.matebridge.yuv444probe/.Y444ProbeActivity --es test t5 [--es clip big.h265 --es w 1848 --es h 1214]`; sonuc `files/y444-results.txt`, satirlar `Y444PROBE t5 codec=... reader=... fmt=...`. Probe Xiaomi'den kaldirildi, gradle daemon durduruldu, MateBridge o sirada force-stop edildi.

Sonuc tablosu (256x144; 1848x1214 ayni; her satir `GPU_EXACT=1`: gpu_y/cb/cr_mis = 0):

| cozucu | ImageReader | MediaFormat | ahb_fmt | CPU planlari = ref? | GPU ham = ref? | OES (donusumlu) vs beklenen |
|---|---|---|---|---|---|---|
| c2.mtk.hevc.decoder, .lowlatency, OMX.MTK.VIDEO.DECODER.HEVC | YUV_420_888 GPU+CPU, YUV GPU-only, PRIVATE GPU, YCBCR_420_888 GPU+CPU, YCBCR GPU-only | varsayilan | 0x7f000010 | HAYIR (cpu_y_mis 36785/36864, max 237; PRIVATE'ta CPU yok) | EVET | max fark 1 (601 limited 256x144; 709 full 1848 klipi) |
| ayni | ayni 5 okuyucu | color-format=Flexible | 0x32315659 (YV12) | EVET (0 mismatch; stride Y 256/1, Cb/Cr 128/1) | EVET | max fark 1 |
| c2.android.hevc.decoder / OMX.google (yazilim) | 5 okuyucu | iki bicim | 0x32315659 | EVET | EVET | max fark 1 |
| c2.mtk.hevc.decoder.secure | - | - | - | - | - | acilamaz (crypto ister) |

CPU hatasi turu (varsayilan MTK tamponu): `Image` stride'lari 256/1,256/2,256/2 raporlanir ama veri anlamsiz (Y0: cpu=191.12.14.74.142.8.157.79, ref=185.189.38.39.56.63.64.66; yani satici/sikistirilmis duzen, CPU okuma yolu bu tampon icin guvenilmez). GPU ornekleri (ilk 8 Y, 4 Cb/Cr, orta satir) ref ile ozdes. Not: `kind=` etiketi her satirda `scrambled_or_converted`; yalniz GPU yanlis oldugunda anlamli, burada GPU dogru. Vendor parametreleri: 53 adet `vendor.mtk.ext.vdec.*` (satira `info vendor_params`); sikistirmayi kapatan bir tanesi denenmedi, gerek yok cunku `color-format=Flexible` CPU'yu da duzeltiyor.

Oneri (ayri uygulama karti; client-android/.../FullChromaSelfTest.kt): oz testte GPU ham okumasi CPU `Image`'a degil bilinen referansa karsilastirilsin: (a) gomulu klibin Y/Cb/Cr'si yazilim cozucu ile bir kez uretilip sabit olarak gomulur (uretim yoluyla ayni 0x7f000010 tamponunu sinar; tercih), ya da (b) test cozucusu `KEY_COLOR_FORMAT=COLOR_FormatYUV420Flexible` ile acilir (MTK CPU'dan dogru okunur ama tampon YV12 olur, uretim duzenini sinamaz). Uretim ImageReader'i PRIVATE+GPU_SAMPLED zaten, ham okuma bit-tam. Ikinci cozucu da her kombinasyonda acildi. Bu cihazda Tam renk kapali kalmasina gerek yok.

Test EDILMEDI: yalniz tek IDR karesi (256x144 ve 1848x1214); 2800x1840 yardimci akisli surekli akis, P kareleri, performans/gecikme (T-254 t1/t3 kosullari) Xiaomi'de olculmedi. MatePad'e dokunulmadi.

## Open questions

- Oz test duzeltmesi icin uygulama karti acilmali (orkestrator karari).
