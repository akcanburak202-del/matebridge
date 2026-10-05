---
id: T-256
title: Probe (tablet) — 4:4:4 GL merge path latency with depth-1 presentation vs today's direct path
status: done
phase: 6
owner: android-client-dev
depends_on: [T-254]
decisions: [0033]
files:
  - probes/yuv444-probe/android/
  - backlog/tasks/T-256-probe-yuv444-gl-latency.md
---

## Amaç

T-254 (NOTES 2026-10-05 ~20:55): GL birleştirme yolu akıcı (HWC, kaçırma yok) ama varış→ekran 55–61 ms, varış→latch 41–48 ms; `draw_call_ms` ~13 ms (eglSwapBuffers bloklanıyor) → üretici BufferQueue'da ~2 kare önde. Büyük olasılıkla probun sunum düzeninden. Bu kart gecikmeyi ürüne yakın sunumla ölçer ve **aynı ölçütle** bugünkü doğrudan yolla (çözücü → SurfaceView) kıyaslar. Hedef (karar kuralı, ölçümden önce): GL yolu varış→ekran p50 ve p95'te doğrudan yola göre **≤ +5 ms** → 4:4:4 uygulamasına geçilebilir; > +10 ms → dur, 0033 kalır; arası → kullanıcıyla konuşulur.

## Bağlam

- Mevcut prob: `probes/yuv444-probe/android` (T-254; `t3`, `direct`, native EGL/GLES kütüphanesi). Ürünün sunum düzeni referans: istemci `video/FramePacer.kt`, `AdaptivePacer.kt`, `SlotReleaser.kt` (`releaseOutputBuffer(ts)`, lead 6 ms, vsync hizalı slotlar) — okunabilir, değiştirilmez.
- **Ölçüt (iki yol için aynı):** "varış" = ana karenin çözücüye verildiği an (probun bugünkü tanımı); "ekran" = gerçek sunum zamanı: GL yolunda `EGL_ANDROID_get_frame_timestamps` (DISPLAY_PRESENT / LATCH), doğrudan yolda `MediaCodec.OnFrameRenderedListener` + mümkünse `Choreographer`/`dumpsys SurfaceFlinger --latency` ile çapraz kontrol. İkisi için p50/p95/p99, kaçırma, sunum aralığı.
- **GL yolu sunum varyantları** (`--es present <mod>`):
  1. `queue` — bugünkü (taban, karşılaştırma için).
  2. `depth1` — bir önceki swap'ın latch'i (frame timestamps ya da fence) gelmeden yeni swap yapılmaz; yeni yardımcı/ana kare gelirse beklerken en yenisi kullanılır.
  3. `pts` — `eglPresentationTimeANDROID` ile ürünün slot mantığına benzer hedef: bir sonraki vsync − lead (vsync: `Choreographer` ya da `EGL_ANDROID_get_frame_timestamps` COMPOSITE_DEADLINE/INTERVAL).
  4. İsteğe bağlı: `swapint0` (eglSwapInterval 0) etkisi.
- Doğrudan yolun da ürün gibi `releaseOutputBuffer(ts)` ile hedefli bırakma varyantı olsun (`--es direct_mode immediate|pts`), böylece kıyas adil.
- T-254'teki hata: `dumpsys SurfaceFlinger --list` seçimi `Background for SurfaceView` katmanını aldı → BLAST `SurfaceView[...]` katmanını seçen yardımcı komutu Handoff bloğunda düzelt.
- Klip: `main_2800x1840_60` / `aux_2800x1840_60` (T-255) ve 1848 karşılığı; 60 fps tempolu; panel 60 ve (dokunma olmadan Huawei izin vermezse not et) 120.
- Sonuç satırı `Y444PROBE lat mode=... path=gl|direct ...`; Handoff'ta kopyala-yapıştır çalıştırma bloğu (orkestratör çalıştırır, MateBridge kapalı, ~10 dk). adb/tablet yok; Mac'te pencere açma.

## Kabul kriterleri

- [x] `assembleDebug testDebugUnitTest` geçer (saf mantık JVM testli: sunum kararı, istatistik).
- [x] Handoff: çalıştırma bloğu, beklenen çıktı, karar kuralı yorumu.

## Plan

Mevcut prob (T-254) uzerine, yalniz `probes/yuv444-probe/android/` icinde:

- **Saf mantik (JVM testli, `Policy.kt`, `LatLine.kt`):** `PresentMode`/`DirectMode` ayristirma, `Depth1Gate` (onceki swap latch'lenmeden yeni swap yok; 100 ms stall'da acilir), `VsyncGrid`/`VsyncEstimator` (Choreographer ornekleri -> periyot + faz), `SlotAllocator` (urunun slot mantigi: `now+lead` sonrasi ilk vsync - lead, ayni slot -> bir sonrakine, sinir asilinca katla), `DisplayEstimate` (direct yolda ekran tahmini), `LatencyVerdict` (karar kurali), `LatLine` (sonuc satiri + p50/p95 ayristirici).
- **GL yolu:** `--es present queue|depth1|pts` (+ `--es swap 0` = swapint0). `depth1`: native `presentOutstanding()` (frame timestamps'ta latch'i henuz PENDING olan swap sayisi); donguda swap oncesi bekle, beklerken gelen kareler birbirinin yerini alir (Mailbox newest-wins). `pts`: `eglPresentationTimeANDROID(slot - lead)`, vsync izgarasi `VsyncTracker` (Choreographer).
- **Direct yolu:** `--es direct_mode immediate|pts`; `pts` = `releaseOutputBuffer(idx, slot - lead)`; ekran zamani `OnFrameRenderedListener` + vsync izgarasi tahmini (EGL zaman damgasi yok), dumpsys ile capraz kontrol.
- **Olcut (iki yol icin ayni):** varis = cozucu cikisi (ImageReader callback / output buffer; T-254'teki tanim), ekran = GL'de DISPLAY_PRESENT (olculen), direct'te render zamani + vsync (tahmin). Sonuc satiri `Y444PROBE lat mode=... path=gl|direct ...`.

## Handoff

- **Kod commit:** 99c60e3 (branch `task/T-256-yuv444-gl-latency`, main f5e08d7 uzerine). `assembleDebug testDebugUnitTest` (probe) gecti: 24 test (10 yeni), 0 hata; `./scripts/check.sh`: ALL OK. **Tabletle hic denenmedi.**
- **Dosyalar:** `probes/yuv444-probe/android/**`: yeni `Policy.kt`, `LatLine.kt`, `VsyncTracker.kt`, `PolicyTest.kt`; degisen `Args.kt`, `ClipDecoder.kt` (`releaseTarget`, `onRendered`), `PresentLoop.kt`, `ProbeRunner.kt`, `Native.kt`, `y444native.cpp` (`presentDraw(..., presentNs)`, `presentOutstanding()`, `eglPresentationTimeANDROID`); bu kart.
- **Yeni argumanlar:** `--es present queue|depth1|pts`, `--es swap 0` (swapint0), `--es direct_mode immediate|pts`, `--es lead_ms 6`, `--es vsync_off_ms 0`.

### Varsayimlar / sinirlar

- **Varis tanimi:** karttaki "cozucuye verildigi an" yerine T-254'teki gercek tanim kullanildi: cozucu CIKISI (GL'de ImageReader callback, direct'te `onOutputBufferAvailable`). Iki yolda ayni; T-254 rakamlariyla (55-61 ms) dogrudan karsilastirilabilir. Besleme->cikis suresi (`decode_pair_ms` / direct `decode_out_ms`) iki yolda ayni cozucu oldugundan farka girmez; kart tanimina cevirmek icin ayni sabit eklenir.
- **Ekran zamani:** GL = `EGL_DISPLAY_PRESENT_TIME` (olculen, `display=measured`). Direct = `OnFrameRenderedListener` render zamani + vsync izgarasi (`display=est`: `nextVsync(render + lead - 1 ms)`); EGL zaman damgasi yok, bu bir **tahmin**. Capraz kontrol icin SF `--latency` (asagida) ve `refresh_hz`; iki yolun tahmini ayni lead ile hesaplanir, fark yorumu bu yuzden izgara fazina duyarli (+-birkac ms).
- **Vsync izgarasi** Choreographer'dan (`VsyncTracker`); Choreographer fazi HWC vsync'inden uygulama vsync ofseti kadar sapabilir. `pts` varyantlarinda `skipped_gaps` artar ya da `slot_folds` > 0 cikarsa `--es vsync_off_ms` (ornegin -4, +4) ile tekrarla. `no_grid` > 0 ise izgara hazir degildi (hedefsiz sunum).
- `depth1`: kapi `COMPOSITION_LATCH_TIME` PENDING sayisina bakar; frame timestamps yoksa kapi hep acik (`features=[frame_timestamps=0 ...]` satirinda gorulur, sonuc gecersiz). `pts`: `present_time=1` olmali (T-254'te EGL_ANDROID_presentation_time = 1).
- `gate_waits`/`gate_wait_ms`: depth1'de kac kez beklendi; `slot_bumps`/`slot_folds`: urun slot mantigi sayaclari.
- Panel 120: Huawei dokunmasiz 60'ta tutuyor (T-254); bu kart esas olarak 60 Hz'de. 120 denemesi yine `--es panel 120` ile, `refresh_hz` gercek hizi gosterir; 60 ise not et, kapat.

### Calistirma blogu (orkestrator, MateBridge istemcisi KAPALI, ekran acik/kilitsiz, ~10-12 dk)

```bash
cd probes/yuv444-probe/android
JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" ANDROID_HOME=~/Library/Android/sdk ./gradlew assembleDebug testDebugUnitTest
ADB=~/Library/Android/sdk/platform-tools/adb
D=~/.cache/matebridge-tools/data/yuv444
P=/sdcard/Android/data/dev.matebridge.yuv444probe/files
A=dev.matebridge.yuv444probe/.Y444ProbeActivity
OUT=$D/t256-run-$(date +%H%M).txt
$ADB shell am force-stop dev.matebridge.client
$ADB install -r app/build/outputs/apk/debug/app-debug.apk
$ADB shell mkdir -p $P
for f in main_2800x1840_60 aux_2800x1840_60 main_1848x1214_60 aux_1848x1214_60; do $ADB push $D/$f.h265 $P/; done
run() { $ADB shell am force-stop dev.matebridge.yuv444probe; $ADB logcat -c; $ADB shell am start -n $A "$@"; }
lat() { sleep 32; $ADB logcat -s Y444PROBE -d | grep -E "Y444PROBE (lat|t3 FAILED|direct (FAILED|no))" | tee -a $OUT; }
# 2800x1840, panel 60: direct taban (2 mod) + GL (4 varyant); her biri ~30 s. Kosullar siralanip ayni oturumda
S="--es size full --es panel 60 --es seconds 20"
echo "== 2800 panel 60" | tee -a $OUT
run --es test direct --es direct_mode immediate $S ; lat
run --es test direct --es direct_mode pts       $S ; lat
run --es test t3 --es present queue  $S ; lat
run --es test t3 --es present depth1 $S ; lat
run --es test t3 --es present pts    $S ; lat
run --es test t3 --es present queue --es swap 0 $S ; lat
# 1848x1214 (kucuk klipler), panel 60
S="--es size small --es panel 60 --es seconds 20"
echo "== 1848 panel 60" | tee -a $OUT
run --es test direct --es direct_mode immediate $S ; lat
run --es test direct --es direct_mode pts       $S ; lat
run --es test t3 --es present depth1 $S ; lat
run --es test t3 --es present pts    $S ; lat
# panel 120 denemesi (2800; Huawei 60'ta tutarsa refresh_hz bunu gosterir, not et)
S="--es size full --es panel 120 --es seconds 20"
echo "== 2800 panel 120" | tee -a $OUT
run --es test direct --es direct_mode immediate $S ; lat
run --es test t3 --es present depth1 $S ; lat
# pts skipped_gaps/slot_folds yuksekse faz sapmasi: --es vsync_off_ms -4 ve +4 ile pts'yi tekrarla
# SF capraz kontrol (BLAST SurfaceView katmani; 'Background for SurfaceView' DEGIL): direct_mode pts ve t3 depth1 calisirken
for t in "direct --es direct_mode pts" "t3 --es present depth1"; do
  run --es test $t --es size full --es panel 60 --es seconds 40 ; sleep 15
  L=$($ADB shell dumpsys SurfaceFlinger --list | grep yuv444probe | grep 'SurfaceView\[' | grep -v Background | head -1); echo "layer=[$L]" | tee -a $OUT
  $ADB shell dumpsys SurfaceFlinger --latency "$L" | head -130 > $D/t256-sf-$(echo $t | cut -d' ' -f1).txt
  sleep 30
done
# karar kurali: GL varyantinin direct 'immediate' ve 'pts'e gore p50/p95 farki (sonuc: PROCEED <= +5, STOP > +10, arasi DISCUSS)
python3 - "$OUT" <<'PY'
import re,sys
rows=[]
for l in open(sys.argv[1]):
    m=re.search(r'lat mode=(\S+) path=(\w+) display=\w+ size=(\S+) fps=\d+ panel_req=(\d+) refresh_hz=\[([^\]]*)\] arrival_to_display_ms=([\d.]+)/([\d.]+)',l)
    if m: rows.append((m[3],m[4],m[2],m[1],float(m[6]),float(m[7]),m[5].split(',')[-1].strip()))
for sz,pn,path,mode,p50,p95,hz in rows:
    if path!='gl': continue
    for b in rows:
        if b[0]==sz and b[1]==pn and b[2]=='direct':
            d50,d95=p50-b[4],p95-b[5]
            v='STOP' if max(d50,d95)>10 else 'PROCEED' if max(d50,d95)<=5 else 'DISCUSS'
            print(f'{sz} panel{pn} hz={hz} gl:{mode} vs direct:{b[3]}  d50={d50:+.1f} d95={d95:+.1f} -> {v}')
PY
```

### Beklenen cikti ve karar kurali yorumu (kural olcumden once: karar GL en iyi varyantinin urun-benzeri direct tabana gore farkina bakar)

- Her kosulda bir `Y444PROBE lat mode=<queue|depth1|pts|immediate|pts[+swapint0]> path=gl|direct display=measured|est ... arrival_to_display_ms=p50/p95/p99/max ... skipped_gaps=.. frames=.. not_shown=..` satiri. `queue` taban (T-254'te ~55-61 ms beklenir); `depth1`/`pts` bunu belirgin dusurmeli (varsayim: ~2 kare onde olma ortadan kalkar, ~25-35 ms).
- **Adil taban = `direct_mode pts`** (urunle ayni slot mantigi); `immediate` ek bilgi. Python ozeti her GL varyantini iki tabanla kiyaslar.
- **PROCEED:** en iyi GL varyanti (aktif surulecek olan) hem p50 hem p95'te direct pts'ye gore <= +5 ms ve `skipped_gaps` ~0, `unresolved` kucuk -> 4:4:4 uygulamasina gecilebilir. **STOP:** > +10 ms (her ikisi icin de en iyi varyantta) -> dur, 0033 kalir. Arasi: kullaniciyla konusulur. Direct tarafi `est` oldugu icin sinira yakin (+-2 ms) sonuclarda SF `--latency` dosyalariyla (`frameReady -> actualPresent` araligi, `desiredPresent`) capraz kontrol et; `refresh_hz` 60 degilse (120) not et.
- `ts_frames`/`frames` dusukse (`unresolved` buyukse) GL tarafi guvenilmez; `features` icinde `frame_timestamps=1 present_time=1` olmali.

## Open questions
