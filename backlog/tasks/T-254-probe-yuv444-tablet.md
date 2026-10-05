---
id: T-254
title: Probe (tablet) — 4:4:4 packing gates: raw YUV sampling on the GPU, ImageReader→GL→SurfaceView presentation, dual decode at 60 fps
status: done
phase: 6
owner: android-client-dev
depends_on: []
decisions: [0033]
files:
  - probes/yuv444-probe/android/
  - backlog/tasks/T-254-probe-yuv444-tablet.md
---

## Amaç

`docs/research/2026-10-05-yuv444-packing.md` §7 P0 probunun tablet yarısı. Kullanıcı (2026-10-05): 4:4:4 yalnız **60 fps** (Günlük 60) için; 120 gerekmez. Karar kuralı ölçümden önce yazılı: T2 ya da T3 olumsuz → dur, 0033 kalır.

## Bağlam

- Ayrı Android projesi `probes/yuv444-probe/android` (paket `dev.matebridge.yuv444probe`; `probes/decoder-concurrency-probe/android` düzeni, elle derlenir). Swift tarafı ve README ayrı kartta (T-255); bu kart yalnız `android/` altına yazar, çalıştırma bloğunu kendi Handoff'una koyar.
- **T2 ham örnekleme (kapı 1):** GLES `GL_EXT_YUV_target` ve Vulkan `VK_KHR_sampler_ycbcr_conversion` + `RGB_IDENTITY` model desteği var mı (uzantı listeleri logla). Bilinen desenli bir klipte (Y/U/V düzlemleri bilinen değerler; klip yoksa T-248 klipleri + yazılım referansı: `ImageReader` YUV_420_888 CPU okuma) GPU'dan ham Y/Cb/Cr okuması bit-tam mı.
- **T3 sunum (kapı 2):** çözücü → `ImageReader` (PRIVATE, GPU örneklenebilir) → GL (ya da Vulkan) basit birleştirme geçişi (iki görüntüden, ikinci yoksa yalnız ana) → `SurfaceView`. 60 fps tempolu besleme; panel 60 ve 120 Hz'te (dokunarak 120'ye çıkıyor). Ölç: çıkış→latch süresi, kare kaçırma, `dumpsys SurfaceFlinger --latency` aralıkları, katmanın HWC/GPU birleşimi, geçiş GPU süresi; bugünkü doğrudan `SurfaceView` çıkışıyla kıyas (aynı klip).
- **T1 çift çözme (60 fps):** iki `MediaCodec` aynı anda (ana + yardımcı; şimdilik iki mevcut T-248/T-249 klibi yeterli, gerçek v2 klipler T-255'ten gelince aynı prob onları da çalar: dosya adı ile). Çift gecikmesi (ana kuyruğa → yardımcı çıktısı) p50/p95/p99/maks, kaçırma; 2800×1840 ve 1848×1214.
- **T4:** 5 dk güç/ısı (T3 açık): `thermal` durumu, pil akımı varsa.
- Sonuç satırları `Y444PROBE` etiketiyle logcat'e + `files/` altına. MateBridge kapalıyken çalışır (orkestratör çalıştırır). adb/tablet yok; Mac'te pencere açma.

## Kabul kriterleri

- [ ] `assembleDebug testDebugUnitTest` geçer; saf mantık (istatistik, ad çözümleme) JVM testli.
- [ ] Handoff: kopyala-yapıştır çalıştırma bloğu (T2, T3 panel 60/120, T1, T4), beklenen çıktı ve kapı yorumları.

## Plan

Ayrı proje `probes/yuv444-probe/android` (paket `dev.matebridge.yuv444probe`, `decoder-concurrency-probe` düzeni, NDK/CMake client-android ile aynı pin). Java'da `eglGetNativeClientBufferANDROID` ve `AHardwareBuffer`->GL içe aktarma yok, bu yüzden küçük bir probe-only C++ (`y444native`, EGL/GLES3/Vulkan sorgusu) var; ürün koduna girmez.

- **Saf mantık (JVM testli):** `Stats.kt` (yüzdelik, `PairLatency` çift gecikmesi, `PresentStats` EGL zaman damgaları), `ClipName`/`SizeSpec` (ad çözümleme), `Args`/`TestKind`/`GlMode`, `RawVerdict`, `PlaneCopy`, `AnnexB`.
- **T2:** `Native.caps()` GL/EGL/Vulkan uzantı listesi (`GL_EXT_YUV_target`, `VK_KHR_sampler_ycbcr_conversion` + özellik, AHB içe aktarma) -> `files/y444-caps.txt`. Ham örnekleme: çözücü -> `ImageReader` YUV_420_888 (CPU okunur + GPU örneklenir) -> `HardwareBuffer` -> EGLImage -> `__samplerExternal2DY2YEXT` ham Y/Cb/Cr -> RGBA8 FBO -> `glReadPixels` vs CPU düzlemleri (Y tam çözünürlükte, Cb/Cr yarım çözünürlükte doku merkezlerinde: bit-tam; ek bilgi: tam çözünürlükte sürücü kroma büyütmesi).
- **T3:** çözücü (ana + aux) -> `ImageReader` PRIVATE (`GPU_SAMPLED_IMAGE`) -> GL iş parçacığı (yeni kare kazanır, EGLImage önbelleği) -> tek birleştirme geçişi -> `SurfaceView` EGL penceresi; `eglGetFrameTimestampsANDROID` (latch/present), `GL_EXT_disjoint_timer_query` GPU süresi, 60 fps tempolu besleyici (`Feeder`, hiçbir erişim birimi atlanmaz). Panel 60/120: `preferredDisplayModeId` + `Surface.setFrameRate`. `direct` = bugünkü çözücü->SurfaceView yolu, aynı klip. HWC/GPU birleşimi ve SurfaceFlinger gecikmesi dumpsys ile (Handoff).
- **T1:** iki `MediaCodec` aynı tickte beslenir; çift gecikmesi = max(ana, aux çıkışı) - kare tick'i; tek akış taban çizgisi ile.
- **T4:** T3'ün 300 sn'lik hali, 10 sn'de bir `thermal`, pil akımı/sıcaklığı, yenileme hızı.
- Merge shader AVC444v2 ters eşlemesi **değil**, maliyet-eşdeğeri (iki ham YUV örneği + parite seçimi + dönüşüm); doğruluk T3 kapısı için gerekmiyor, süre/bellek trafiği ölçülür.

## Handoff

- **Commit:** 38f5486 (branch `task/T-254-yuv444-tablet-probe`, main 07a4f71 uzerine). `assembleDebug testDebugUnitTest` (probe) gecti: 14 test, 0 hata, `libY444native.so` (arm64-v8a) derlendi. `./scripts/check.sh`: ALL OK (probe check.sh'a girmez, elle derlenir).
- **Dosyalar:** `probes/yuv444-probe/android/**` (Kotlin + `src/main/cpp/y444native.cpp`), bu kart. Swift tarafina/README'ye dokunulmadi.
- **Tabletle hic denenmedi.** Bilinmeyenler asagida.

### Varsayimlar / sinirlar

- Merge shader AVC444v2 ters eslemesi degil, **maliyet-esdegeri** (iki ham YUV ornegi, parite secimi, BT.709 tam aralik donusum). T3 kapisi sure/bellek trafigi/panel hizi ister, dogruluk degil.
- Ana ve aux kare eslemesi yok: GL gecisi en yeni ana + son gelen aux ile cizer (olcum amacli). Aux yoksa (`aux=none` ya da `gl=main|oes`) tek goruntu.
- Vulkan yalniz yetenek sorgusu (cihaz uzantilari + `samplerYcbcrConversion` ozelligi); Vulkan ile ham ornekleme/sunum **yok**. `RGB_IDENTITY` ozelligiyle zorunlu, ayri sorgulanmiyor. GL yolu olumsuzsa Vulkan icin ayri kart gerekir.
- T2 referansi: cozucunun YUV_420_888 ciktisinin CPU okumasi (bilinen desenli klip yok). Cb/Cr bit-tamligi yarim cozunurlukte doku merkezlerinde olculur (tam cozunurlukte surucunun kroma buyutmesi `fullres_cb_mis` olarak yalniz bilgi).
- Klip adlarinda `<W>x<H>` aranir; 10-bit T-249 klipleri varsayilan secimden haric (adla verilebilir). 1848x1214 klibi su an yok: T-255 klipleri gelince `size=small` ya da `main=<ad> aux=<ad>`.
- Hizli yol: ham ornekleme `EGL_ANDROID_get_native_client_buffer` + `eglCreateImageKHR` ile; ikisi yoksa `presentInit`/`rawInit` metinle FAIL doner (gate 1 FAIL).
- Panel 60/120: `preferredDisplayModeId` (ayni cozunurluklu en yakin mod) + `Surface.setFrameRate(hz, FIXED_SOURCE)`; HarmonyOS bunu yok sayabilir. Gercek hiz `refresh_hz_samples` ve `dumpsys` ile dogrulanir; 120 icin gerekirse ekrana dokunun (kullanici notu).
- `ui=1` verilmedikce durum metni gizli (ust katman bindirmesi birlesimi bozmasin). Sonuclar logcat'te ve `files/y444-results.txt`'te.

### Calistirma bloku (orkestrator, MateBridge istemcisi KAPALI, ekran acik/kilitsiz, tek cihaz testi)

```bash
cd probes/yuv444-probe/android
JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" ANDROID_HOME=~/Library/Android/sdk ./gradlew assembleDebug testDebugUnitTest
ADB=~/Library/Android/sdk/platform-tools/adb
D=~/.cache/matebridge-tools/data/decprobe
P=/sdcard/Android/data/dev.matebridge.yuv444probe/files
A=dev.matebridge.yuv444probe/.Y444ProbeActivity
$ADB shell am force-stop dev.matebridge.client
$ADB install -r app/build/outputs/apk/debug/app-debug.apk
$ADB shell mkdir -p $P
for f in full_2800x1840_8_60m full_2800x1840_8_80m; do $ADB push $D/$f.h265 $P/; done
CL="--es main full_2800x1840_8_60m --es aux full_2800x1840_8_80m"
run() { $ADB shell am force-stop dev.matebridge.yuv444probe; $ADB logcat -c; $ADB shell am start -n $A "$@"; }
# T2 (kapi 1): uzanti listeleri + ham ornekleme bit-tamligi (~15 s)
run --es test t2 $CL
$ADB logcat -s Y444PROBE -d | grep -E "t2 (caps|raw|gate1)"        # veya: $ADB pull $P/y444-caps.txt /tmp/
# T1 (60 fps cift cozme; once tek akis, sonra ana+aux; 20 s'er)
run --es test t1 $CL ; sleep 55 ; $ADB logcat -s Y444PROBE -d | grep "Y444PROBE t1"
# Dogrudan SurfaceView tabani (ayni klip) ve T3 GL birlestirme, panel 60 sonra 120 (her biri ~25 s)
for hz in 60 120; do
  run --es test direct --es panel $hz $CL ; sleep 32 ; $ADB logcat -s Y444PROBE -d | grep "Y444PROBE direct"
  run --es test t3 --es panel $hz $CL ;     sleep 32 ; $ADB logcat -s Y444PROBE -d | grep "Y444PROBE t3"
done
# Katman birlesimi (HWC mi GPU mu) ve SurfaceFlinger gecikmesi: bir test calisirken (ornek T3 panel 60, seconds 60)
run --es test t3 --es seconds 60 $CL
sleep 15
L=$($ADB shell dumpsys SurfaceFlinger --list | grep yuv444probe | grep -i SurfaceView | head -1); echo "$L"
$ADB shell dumpsys SurfaceFlinger --latency "$L" | head -130 > /tmp/y444-sf-latency-t3.txt
$ADB shell dumpsys SurfaceFlinger | grep -B2 -A12 "yuv444probe" | grep -iE "composition|HWC|Device|Client|SurfaceView" | head -20
# ayni dumpsys'i '--es test direct' calisirken tekrarla (taban); /tmp/y444-sf-latency-direct.txt
# T4 (5 dk guc/isi, T3 acik; sample satirlari 10 s'de bir)
run --es test t4 $CL ; sleep 330 ; $ADB logcat -s Y444PROBE -d | grep -E "Y444PROBE t4"
# 2240x1472 / 1848x1214: T-255 klipleri gelince  --es main <klip> --es aux <klip>
```

### Beklenen cikti ve kapi yorumu (karar kurali: T2 ya da T3 olumsuz -> dur, 0033 kalir)

- `t2 gate1_caps gl_yuv_target=yes` ve `t2 raw ... y_mis=0/... cb_mis=0/... cr_mis=0/...` + `t2 gate1 verdict=PASS`. `FAIL reason=raw_samples_differ` (yani GPU ham degeri degistiriyor/kirpiyor) ya da `gl_yuv_target=no` = **kapi 1 olumsuz** (Vulkan yetenek satiri `vk_ycbcr_conversion` yalniz ek bilgi; Vulkan yolu icin ayri deney gerekir). `INCONCLUSIVE` = ImageReader YUV_420_888 cikisi desteklenmedi, T2 baska yolla tekrar edilmeli (karar degil).
- `t3 ... skipped_gaps=0` (present_gap p99 ~ besleme periyodu 16.7 ms), `drawn` ~ `ticks`, `draw_errors=0`, `error=null`, `unresolved_ts` kucuk, `refresh_hz_samples` istenen hizda (60 ve 120'de), `arrival_to_latch_ms` ve `arrival_to_swap_ms` p99 tek kare periyodu (16.7 ms) altinda, `gpu_ms_mean` ~1-2 ms (arastirma tahmini; `gpu_timer=0` ise `draw_call_ms`'e bak), `decode_pair_ms` p50 ~ 13 ms + 3-13 ms (T1 ile tutarli). `direct` ile `dumpsys --latency` araliklari kiyaslanir: GL yolu belirgin kare kacirir, panel 120'de 60'a duser ya da katman GPU (Client) birlesimine gecerse **kapi 2 olumsuz**. Sayisal esikler karti yazan orkestratorun; yukaridakiler yalniz yorum rehberi.
- `t1 single` / `t1 dual`: `pair_ms` p50/p95/p99/maks, `aux_after_main_ms`, `missed_main/aux=0`, `main_only/aux_only/neither` ~0; arastirma tahmini cift gecikmesi +3-13 ms.
- `t4 sample` satirlari: `thermal` (0-1 iyi), `current_now_ua` (isaret cihaza gore), `refresh_hz` degismemeli; son `t4` satiri `thermal=a->b` ve skipped_gaps'in 5 dk boyunca bozulmadigini gosterir.

## Open questions

- Vulkan sunum/ham ornekleme yolu bu probda yok (yalniz sorgu). GL kapisi gecmezse karar vermeden once Vulkan icin ayri kart gerekip gerekmedigi orkestratore ait.
- `RGB_IDENTITY` destegi Vulkan'da ozellikten turetildi, dogrudan olculmedi.
- `GL_EXT_YUV_target` varsa bile `texture()` ham deger donusu surucuye bagli; T2 bunu bit-tam olcer, ama chroma siting/upsampling (tam cozunurlukte) surucu davranisi urun tasariminda ayrica dikkate alinmali (`fullres_cb_mis` bilgi satiri).
