---
id: T-278
title: Client — yerel imleç v2: tablette konum tahmini (göreli hareket + mutlak kalem/dokunma), host durumuyla uzlaştırma
status: review
phase: 6
owner: android-client-dev
depends_on: [T-276]
decisions: [0036]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/
  - client-android/app/src/test/kotlin/dev/matebridge/client/
  - docs/decisions/0036-local-cursor.md
  - backlog/tasks/T-278-cursor-prediction.md
---

## Amaç

Karar 0036 v1: imleç host'un bildirdiği konumda çiziliyor (gecikme ≈ RTT + vsync: USB birkaç ms, Wi-Fi ~15–25 ms). v2 (0036 "Tekrar düşünülür"; kullanıcı 2026-10-06 onayladı): tablet, kendi gönderdiği girdiden imlecin nereye gideceğini **hemen** tahmin edip çizer; host'tan gelen `CURSOR_STATE` gerçeği düzeltir. **Protokol değişmez** (tahmin yalnız istemcide; `CURSOR_STATE.host_time_us` + mevcut saat farkı tahmini kullanılır).

## Kabul

1. **Göreli hareket (fare, trackpad, `POINTER_REL`):** host göreli hareketi nokta cinsinden 1:1 uygular, hızlanma yok (MacEvent: "raw movement in whole points"; hız çarpanı tablette uygulanıyor). Tablet gönderdiği her deltayı (nokta, kesir taşıma dahil, gönderim zamanıyla) sınırlı bir halkada tutar. Tahmin = son kabul edilen `CURSOR_STATE` konumu + o durumun host'ta örneklendiği andan **sonra** host'a varmış sayılan deltalar (varış ≈ gönderim + tek yön gecikme tahmini; mevcut PING saat farkı/RTT). Ekran sınırına sıkıştır (`STREAM_CONFIG.width_pt/height_pt`, normalize). Gizli imleçte (`visible=0`) tahmin yapılmaz.
2. **Mutlak (kalem hover/temas, parmak dokunma, `POINTER_ABS`):** konum tam bilinir → imleç hemen o noktaya çizilir; sonraki STATE ile uzlaşır.
3. **Uzlaştırma:** yeni STATE gelince tahmin yeniden hesaplanır; sapma küçükse (≤ ~4 nokta) yumuşak geçiş (1–2 kare), büyükse anında atla (uygulama imleci taşıdı/warp). Hareket durunca tahmin ≤ ~100 ms içinde host konumuna oturur. Tahmin hiçbir zaman girdi yoluna geri beslenmez (yalnız çizim).
4. Oyun modu / `visible=0` / imleç Görüntüde: tahmin kapalı (bugünkü davranış). Geliştirici düğmesi: `--ez dev true --ez cursor_predict false` (varsayılan açık).
5. Ölçüm logu: saniyelik `cursor_stats`'a `pred_err_pt_p50/p95` (tahmin ile sonraki STATE farkı) ve `pred_n`.
6. JVM testleri: delta halkası ve varış kesimi, sınıra sıkıştırma, mutlak giriş, uzlaştırma (küçük/büyük sapma, durunca oturma), gizli/oyunda kapalı.
7. 0036'ya kısa ek (v2 tahmin, protokol değişmeden). `./scripts/check.sh`. Mac'te pencere açma, tablete dokunma.

## Plan

1. `cursor/CursorPredictor` (saf Kotlin, kilitli): InputOutbox'tan gönderilen PointerRel (dx,dy nokta), PointerAbs ve Pen (son IN_RANGE/CONTACT örneği) için gönderim anıyla (istemci monotonik saati) 512'lik halka; en son CURSOR_STATE bir "anchor" (konum, host örnekleme anı istemci saatine `hostTime - offset`, en çok `rx - tek yön`'e kısıtlı; offset yoksa `rx - tek yön`).
2. Tahmin = anchor konumu + (gönderim + tek yön > anchor örnekleme anı) olan, gönderimi <= şimdi ve yaşı < 100 ms olan olaylar sırayla (REL topla + sınıra sıkıştır, ABS konumu ata). 100 ms'den eski olaylar "yerleşti" sayılır (host durunca <= 100 ms'de host konumuna oturma).
3. Uzlaştırma (yalnız UI/çizim): yeni anchor görülünce `eskiHedef + düzeltme - yeniHedef` <= 4 pt ise düzeltme olarak taşınır ve exp(-dt/10 ms) ile sönümlenir; büyükse anında atlar.
4. Ölçüm: yeni STATE gelince önceki anchor + olaylarla o durumun örnekleme anına tahmin edilen konum ile gerçek konum farkı -> `CursorStats.onPred(err, hold)`; `cursor_stats`'a `pred_err_pt_p50/p95`, `pred_n`, `hold_err_pt_p50/p95` (tahminsiz "son STATE'te kal" farkı, karşılaştırma için).
5. Bağlantı: InputOutbox'a `observer` (iletim başarılı olunca), InputCapture.sentObserver, CursorLink predictor'ı state/oturum/enable ile besler, CursorOverlayView redrawTask'ta (vsync öncesi) tahmini hesaplayıp kirli dikdörtgeni eski+yeni kutuyla birleştirir, onDraw aynı sonucu kullanır; animasyon gerektikçe bir sonraki kareyi ister. `--ez dev true --ez cursor_predict false` (DevKnobs).
6. JVM testleri: CursorPredictorTest (halka/varış kesimi, sıkıştırma, mutlak, uzlaştırma, durunca oturma, gizli/kapalı, ölçüm), RedrawGate, CursorStats, DevKnobs, InputOutbox observer.
7. 0036'ya v2 eki.

## Handoff

- **Kod commit:** f39e2375 (dal `task/T-278-cursor-prediction`; bu kartın commit'i onun üstünde). `./scripts/check.sh`: ALL OK (CursorPredictorTest 18 test dahil).
- **Dosyalar:** yeni `cursor/CursorPredictor.kt` (+ test); değişen `CursorLink.kt` (predictor'ı durum/enable/oturumla besler), `CursorOverlayView.kt` (redrawTask vsync'te tahmini sabitler, kirli alan = eski kutu + yeni kutu, `onDraw` aynı konumu çizer, animasyon gerektikçe sonraki kareyi ister), `CursorStats.kt` (pred/hold alanları), `RedrawGate.kt` (`requestRecompute`), `input/InputOutbox.kt` (`observer`, yalnız sink'e başarıyla verilen mesajlar), `input/InputCapture.kt` (`sentObserver`), `session/DevKnobs.kt` (`cursor_predict`), `MainActivity.kt` (bağlantı), 0036'ya ek, testler.
- **Varsayımlar:** (1) Tahmin yalnız `POINTER_REL`'den; kalem/parmak/`POINTER_ABS` 300 ms askıya alır (v1 gecikmesi). (2) Tek yön gecikme = en iyi RTT / 2 (yoksa 5 ms). (3) Durum örnekleme anı = `host_time - offset`, en çok `varış - tek yön`; offset yoksa `varış - tek yön`. (4) "Yerleşme" 100 ms (`SETTLE_US`), yumuşak geçiş eşiği 4 pt, sönüm ~10 ms.
- **Test edilmedi (tablet gerekir):** gerçek ekranda görsel akıcılık, kirli-dikdörtgen kırpması (HW canvas'ta imleç izi/hayalet kalıyor mu), Wi-Fi'da saat farkı kaymasının etkisi, kalem/parmak askıya alma geçişinin görsel temizliği.
- **Cihazda bak (tek oturum, USB sonra Wi-Fi):**
  1. Normal açılış (Günlük mod, İmleç: Tablette). Trackpad/fare ile hızlı hareket ettir: imleç parmakla birlikte anında hareket etmeli (v1'de gecikmeli). Aynı oturumu `--ez dev true --ez cursor_predict false` ile aç, farkı karşılaştır.
  2. Hareketi aniden durdur: imleç <= ~100 ms'de Mac'teki konuma oturmalı, geri/ileri sallanma ya da kalıcı kayma olmamalı. Ekran kenarına sür: kenarda durmalı, taşmamalı.
  3. Kalem hover ve parmak dokunma: tahmin yok (host konumu, v1 gecikmesi); iz/hayalet (eski konumda kalan imleç) olmamalı; kalem/parmak bırakıldıktan ~300 ms sonra fare/trackpad tahmini geri gelir. Bir uygulama imleci taşıyorsa (ör. sürükleme sırasında warp) anında atlamalı.
  4. Yazarken (imleç gizlenir) ve Oyun modunda tahmin olmamalı (bugünkü davranış).
  5. Log: `adb logcat -s 'MB:*'` içinde `cursor_stats` satırı. `pred_err_pt_p50/p95`: önceki durumun tahmininin sonraki durumdan sapması (Mac noktası; 1 pt ~ 2 piksel). `hold_err_pt_p50/p95`: tahmin yapılmasaydı (son durumda kalsaydı) sapma. Beklenen: `pred_err` belirgin biçimde `hold_err`'den küçük (USB: p95 birkaç pt altı, Wi-Fi biraz büyük). `pred_err` >= `hold_err` ise saat farkı/tek yön tahmini yanlış demektir (Wi-Fi asimetrisi): o durumda `cursor_predict false` ile v1'e dönülür ve rapor edilir. `pred_n` o saniyedeki ölçüm sayısıdır (yalnız konum değişen ya da tahmini olan durumlar). `age_ms_*` v1'deki gibi durum yaşıdır (tahminle değişmez).
- **Codex --high düzeltmeleri (2 x P2):** (1) `onDraw` dondurulmuş konumu yalnız hâlâ en yeni kabul edilmiş durum ise kullanır (`FrozenFrame.usable`: kimlik, visible, yaş; gizleme/yeni seq/oturum sıfırlaması onu geçersiz kılar) ve okuyucu iş parçacığı her kabul edilen durumda (kutu olmasa da) bir kare ister (`requestRedrawAlways`), böylece çizilmemiş imleci gizleyen durum eski kareyi ekranda bırakmaz. (2) Sahiplik aynası kaldırıldı (aşağıdaki "Sadeleştirme" ile değişti).
- **Sadeleştirme (Codex ikinci tur, 2 x P2: araç değişimi/çift dokunuş mandalı, geçiş yarışı):** (a) Tahmin YALNIZ `POINTER_REL`'den; sahiplik aynası tamamen silindi. Herhangi bir `PEN` örneği ya da `POINTER_ABS` tahmini son örnekten 300 ms sonrasına dek askıya alır (`SUSPEND_US`; halka boşalır, o sürede v1: host konumu çizilir), sonra göreli tahmin sürer. Düğme basılıyken (fare/trackpad sürükleme) tahmin aynen sürer. Askıya geçişte ve tahminsiz karede eski kutu da kirli alana girer (`redrawTask`). (b) Her gözlem nesil damgalı: `CursorPredictor.onSent(msg, nowUs, gen)`; `MainActivity` gözlemciye gönderimin yapıldığı `inputGen`'i verir, `CursorLink.beginSession(gen)` silahlar, `endSession` ve oturum başı halkayı boşaltır; eski nesil gözlemi yok sayılır. Testler (22): kalem 300 ms askıya alır sonra sürer, `POINTER_ABS` askıya alır, düğme basılıyken tahmin sürer, eski nesil yok sayılır, halka oturum başı/sonunda boşalır; sahiplik testleri silindi, donmuş kare testi duruyor. Cihazda ek kontrol: trackpad ile hareket ederken kalem yaklaştır, imleç ~300 ms host konumunda (gecikmeli ama sıçramasız) kalır, kalem çekilince tahmin geri gelir.
- **Not:** `docs/KNOBS.md` kartın `files:` listesinde olmadığı için `cursor_predict` oraya eklenmedi (orkestratör ekler).

## Open questions

- `docs/KNOBS.md`: `--ez cursor_predict false` satırı eklenmeli (kart kapsamı dışı).
- Tahmin ufku şu an "çizim anı"; ekranda gösterim gecikmesi (~yarım vsync) için ileri öteleme yok. Ölçüm sonrası gerekirse ayrı kart.
