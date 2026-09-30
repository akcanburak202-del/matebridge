---
id: T-056
title: Tablet — yerel kalem göstergesi (imleç noktası + kısa sönümlenen iz) ile algılanan gecikmeyi azalt
status: done
phase: 5
owner: android-client-dev
depends_on: [T-052]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/overlay/
  - client-android/app/src/main/kotlin/dev/matebridge/client/input/
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/Settings.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/
  - backlog/tasks/T-056-client-local-pen-overlay.md
---

## Amaç

PLAN Aşama 2/5: "Kalem gecikmesi … gerekirse tablette yerel imleç/hover noktası", "kalem için tahmini ink". Uçtan uca gecikme (kalem → Mac → kodlama → ağ → çözme → sunum) Performans modunda ~25–35 ms; kalem ucu ile çizgi arasında görünür boşluk bırakır. Tablet kalemin gerçek konumunu anında biliyor: bunu video üstünde yerel olarak göstermek algılanan gecikmeyi kapatır. Yeni bağımlılık yok (androidx.input tahmincisi karar gerektirir; bu kartta yok).

## Kabul kriterleri

- [ ] Video yüzeyinin üstünde saydam bir katman (ayrı `View` ya da `SurfaceView` Z-sıralı; donanım hızlandırmalı `Canvas`); kalem örnekleri (mevcut `PenTracker` akışından, unbuffered dispatch dahil) çizim iş parçacığında değil UI'da en az gecikmeyle işlenir; katman `postInvalidateOnAnimation` ile vsync'te çizilir.
- [ ] **Hover:** kalem menzildeyken küçük bir nokta (ör. 6 dp halka) kalemin konumunda. **Temas:** son ~40 ms'lik örneklerden kısa bir iz (çizgi), zamanla sönümlenir (ör. 60–80 ms'de kaybolur) — Mac'ten gelen gerçek çizgi o arada yetişir. Kalınlık basınçla orantılı, renk nötr yarı saydam (gerçek fırça rengini bilemeyiz).
- [ ] Silgi modunda (karar 0006) iz çizilmez, yalnızca halka.
- [ ] Ayar: bağlantı panelinde "Kalem izi: açık/kapalı" ve "Kalem noktası: açık/kapalı" (`Settings`, varsayılan: nokta açık, iz açık). İz süresi sabiti tek yerde.
- [ ] Performans: katman çizimi kare başına < 1 ms; video sunumunu ve T-052 zamanlamasını etkilemez (katman ayrı; video yüzeyi yeniden çizilmez).
- [ ] Koordinatlar: mevcut görünüm alanı/letterbox dönüşümüyle (T-050 `VideoLayout`) — iz video üstündeki doğru yere çizilir.
- [ ] Saf mantık (iz tamponu, sönümleme, zaman penceresi) birim testli. `./scripts/check.sh` geçiyor.

## Kapsam dışı

- Host. Tahmin (ileriye çizim) — ileride, karar gerekebilir. Cihaz testi orkestratör + kullanıcı (kalemle).

## Plan

1. `overlay/PenInkModel.kt` (saf, JVM testli): sabit boyutlu halka tampon (zaman, x, y, basinc, vurus-baslangici); nokta durumu (hover/temas/silgi); `forEachSegment(now)` son 40 ms penceresi ve 70 ms dogrusal sonumleme; sabitler `PenInkStyle` icinde tek yerde.
2. `input/PenInkListener.kt`: `InputCapture.onPen` kabul edilen her kare icin agdan once dinleyiciyi cagirir (PenTracker'in dogrulama/bekletmesinden bagimsiz, yani gosterge Mac gidis-donusunu beklemez); `forget()` (release-all/oturum sifirlama/kaynak kaybi) dinleyiciyi temizler. Silgi = silgi ucu VEYA cift dokunusla yerel ayna bayragi (host her DOUBLE_TAP'te degistirir; forget'te sifirlanir).
3. `overlay/PenOverlayView.kt`: root'un ustune saydam, dokunulmaz View; donanim hizlandirmali Canvas, `postInvalidateOnAnimation` ile vsync; video viewport'una clip (letterbox disinda cizim yok); model koordinatlari zaten root/viewport uzayinda.
4. `Settings`: `penTrail()` / `penDot()` (varsayilan acik). MainActivity: katman eklenir, baglanti paneline iki dugme, ayarlar modele yansir; viewport degisince katmana verilir.
5. Testler: model (pencere, sonumleme, vurus kirilmasi, silgi, kapali ayarlar, ring tasmasi), Settings, InputCapture dinleyici/clear/eraser ayna.


## Handoff

- **Commit:** (bkz. branch `task/T-056-client-local-pen-overlay` ucu; SHA orkestratore raporlandi)
- **Dokunulan dosyalar:** `overlay/PenInkModel.kt`, `overlay/PenOverlayView.kt` (yeni), `input/PenInkListener.kt` (yeni), `input/InputCapture.kt` (`penInk` kancasi + eraser aynasi), `session/Settings.kt` (`penTrail`/`penDot`), `MainActivity.kt` (katman, iki panel dugmesi), testler: `overlay/PenInkModelTest`, `InputCaptureTest`, `SessionSupportTest`.
- **Varsayimlar:** Katman root'a eklenir, stats metninin altinda / videonun ustunde; koordinatlar `PenFrame` ile ayni root uzayinda, cizim `VideoViewport` dikdortgenine klip edilir. Gosterge `InputCapture.onPen` icinde, `PenTracker` bekletmesinden (T-029 10 ms onay) onceki kareyi gorur: yani nokta/iz aga gitmeyi beklemez. Silgi = `TOOL_TYPE_ERASER` VEYA cift dokunusla yerel ayna bayragi (host her DOUBLE_TAP'te degistirir; release-all/oturum sifirlamada sifirlanir). Ayna, host bir PEN_GESTURE'i yok sayarsa sapabilir. Iz rengi nötr gri (0x8C8C8C) yari saydam; nokta: hover'da halka, temasta dolu, silgide buyuk halka. Sabitler: `PenInkStyle` (pencere 40 ms, sonum 70 ms, alfa 0.55).
- **Test edilmeyenler / cihazda doğrulanacaklar:** Gercek kalemle: (1) hover'da nokta kalemi gecikmesiz izliyor mu; (2) cizerken kisa iz Mac cizgisinin onunde mi, 70 ms'de kayboluyor mu, kalinlik basincla artiyor mu; (3) letterbox bandinda cizim yok, noktalar video ile hizali; (4) cift dokunus sonrasi yalniz halka, iz yok (Krita silgi); (5) panelden "Kalem izi"/"Kalem noktasi" kapat/ac etkisi ve kalicilik; (6) video karesi/pacing (stats) katman yuzunden bozulmuyor; (7) kalem menzilden cikinca/uygulama arka plana gidince nokta kayboluyor. Frame basina <1 ms ciziim sure olculmedi. Sol alt kose gibi yerlerde GL yolunda (`--es render gl`) z-sirasi da kontrol edilmeli.
- **Açık sorular:** Kalem menzil disina cikar ama HOVER_EXIT gelmezse nokta ekranda kalir (zaman asimi yok; duran kalem hover olayi uretmedigi icin bilerek eklenmedi).

## Orkestratör notu (merge, 2026-10-01)

- Kod merge edildi ve tablete kuruldu; kalemle cihaz denemesi kullanıcıyla (sabah). Silgi modu yerel bayrakla tahmin ediliyor (kayabilir); 250 ms örneksiz kalınca nokta gizleniyor.
