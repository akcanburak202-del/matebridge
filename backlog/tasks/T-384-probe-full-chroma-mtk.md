---
id: T-384
title: Probe (Xiaomi Pad Mini, MTK) — tam renk ham GPU okuması neden tutmuyor; çalışan bir yol var mı
status: todo
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

## Handoff

## Open questions
