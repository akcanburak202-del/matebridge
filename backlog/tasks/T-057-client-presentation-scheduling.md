---
id: T-057
title: Tablet — sunum zamanlaması düzeltmeleri (yuva başına tek bırakma, son yuvaya gecikme sınırı, faz kalibrasyonu, çözücü doluluğu)
status: done
phase: 5
owner: android-client-dev
depends_on: [T-052]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/
  - client-android/app/src/test/
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - backlog/tasks/T-057-client-presentation-scheduling.md
---

## Amaç

NOTES 2026-10-01 ~02:20 (ölçüm + gpt-6-astra danışması). Kalan takılma: 120 Hz'te %2,4–4,8 tekrar kare, 60 Hz'te (akış 120) %6–8 33 ms boşluk. Kullanıcı: "akıcı, stutter olmayan görüntü çok önemli".

## Kabul kriterleri

- [ ] **Yuva başına tek bırakma:** `drainOutput`'ta çekilişler arası çarpışma bugün önceki bırakmayı geri alamıyor (yalnızca sayaç). Bir hedef vsync yuvası için en fazla **bir** `releaseOutputBuffer(idx, ns)`; aynı yuvaya düşen daha yeni kare için en fazla **bir değiştirilebilir bekleyen çıkış** tutulur ve ölçülen bir gönderim son anına (deadline) kadar bekletilir; son anda en yeni olan bırakılır, diğeri `releaseOutputBuffer(idx, false)`. Tutulan çıkış arabelleği sayısı sınırlı (en çok 1 bekleyen).
- [ ] **Gecikme sınırı son yuvada:** `AdaptivePacer`'da sınır `D`'ye değil, **nihai sunum yuvasına** uygulanır (en erken olası sunuma göre ≤ 1 vsync + pay); geç kalan kare sonraki boş yuvaya itilmez, daha yeni kare varsa atılır. `D` en çok ~1,5 P (bugün 3P'ye kadar çıkabiliyor).
- [ ] **Faz:** vsync ızgarası `Display.getAppVsyncOffsetNanos()` ve `presentationDeadlineNanos` hesaba katılarak kurulur; `slot − P/2` varsayımı yerine ayarlanabilir bir öncü (lead) sabiti; taban ve jitter hedefi ani değil yumuşak (slew) değişir; boşta kalma ve panel hızı değişiminden sonra yeniden çapalama; faz/periyot tek tutarlı anlık görüntüden okunur, kaçırılan Choreographer geri çağrısı ile gerçek mod değişimi ayırt edilir.
- [ ] **Çözücü doluluğu:** gönderilen − çıkan kare sayısı (`in_codec`) ölçülür ve istatistiğe yazılır; `--ei inflight N` (2/3/4, varsayılan bugünkü davranış ya da ölçüme göre) ile sınır denenebilir; kuyruktaki `held` kare de sayılır.
- [ ] İstatistik: `MB/render` satırına `slot_dups` (aynı yuvaya ikinci bırakma girişimi), `late_drops`, `in_codec_p95`, `lead_ms`.
- [ ] Saf mantık birim testli (yuva seçimi, bekleyen çıkış değişimi, son yuva sınırı, faz yumuşatma, 60/120 Hz ve 120 fps→60 Hz). `./scripts/check.sh` geçiyor.

## Kapsam dışı

- Panel hızını host'a bildirme (T-059). Host (T-058). SurfaceControl. Cihaz ölçümü orkestratörde (SF `--latency`, uzun pencereler).

## Plan

- **Kapsam notu:** `MainActivity.kt` kart `files:` listesinde yok; bu yüzden cihaz bilgisi/intent bağlantısı (`Display.getAppVsyncOffsetNanos`, `presentationDeadlineNanos`, `--ei inflight`, `--ei lead`) `VsyncClock`/`VideoRenderer` üzerinde ayarlayıcı (setter) olarak sunulur; bağlantıyı orkestratör yapar. Yeni istatistik satırı `VideoRenderer.onSkipWindow` içinden (MainActivity'nin mevcut saniyelik çağrısı) `MB/render ev=present` olarak yazılır.
- **VsyncClock:** tek tutarlı `Grid(lastNs, periodNs, epoch, deadlineNs)` anlık görüntüsü; `setDisplayTiming(appOffset, deadline)` (görüntü-alanı = Choreographer − appOffset); `epoch` yalnızca gerçek periyot değişiminde (>%10: `setNominalHz` ya da yeniden tohumlama) artar. Kaçırılan geri çağrı (aralık = tam kat, tek seferlik) periyodu bozmaz; tam kat aralıklarla yeniden tohumlama için daha uzun kanıt (12) gerekir (asıl yetkili kaynak ekran dinleyicisi). `leadNs()` = override ya da P/2.
- **AdaptivePacer:** epoch değişince sıfırla; boşta (>1 sn) yeniden çapa; taban `b` ve `D` yumuşak değişir (slew, yukarı/aşağı ayrı sabitler); hedef = capture + b + D + presentationDeadline; en erken yuva = `ilk vsync >= şimdi + deadline`; nihai yuva `en erken + P`'yi aşamaz (kıstırılır); önceki yuvaya çarparsa ve `+P` sınırı aşılırsa yeni kare önceki yuvayı paylaşır (collided, `lateDrop`); `D` tavanı 1,5 P (fazla içerikte P).
- **SlotReleaser (yeni, saf):** yuva başına tek `release`; aynı yuvaya ikinci kare: bekleyen değiştirilir (eski atılır, `slot_dups`), zaten bırakılmış yuvaya ise yeni kare atılır. En çok 1 bekleyen çıkış; gönderim son anı = yuva − `dispatchLead` (bilinmiyorsa P), geçmişse hemen bırakılır; çıkış iş parçacığı bekleme süresini son ana göre kısaltır.
- **InFlightGauge (yeni, saf):** gönderilen − (bırakılan/atılan) sayacı, pencere p95 histogramı, `canQueue(limit)` (limit 0 = sınırsız = bugünkü davranış; 100 ms çıkış olmazsa kilitlenmemek için serbest bırakır).
- **Sayaçlar/istatistik:** `PresentCounters` (slot_dups, late_drops) + `StatsFormat.presentFields` -> `MB/render ev=present slot_dups late_drops in_codec_p95 lead_ms d_us`.
- **Testler:** SlotReleaserTest (yuva çarpışması, bekleyen değişimi, son an, tek bırakma), InFlightGaugeTest, AdaptivePacerTest ek (son yuva sınırı, D tavanı, slew, idle re-anchor, 60/120 ve 120 fps->60 Hz), VsyncClockTest (epoch, kaçırılan geri çağrı, offset), StatsFormat.

## Handoff

- **Commit:** ddaa19d (kod), plan ayrı commit; `./scripts/check.sh` geçti.
- **Dokunulan dosyalar:** `video/AdaptivePacer.kt`, `video/FramePacer.kt` (VsyncClock + Decision), `video/SlotReleaser.kt` (yeni: SlotReleaser, PresentCounters, InFlightGauge), `video/VideoRenderer.kt`, `stream/StatsFormat.kt`, testler (`PresentationSchedulingTest.kt` yeni; `AdaptivePacerTest`/`PacingTest` yalnızca `RESEED_AFTER_MULTIPLE` uyarlaması).
- **Varsayımlar:**
  - Yuva başına tek bırakma: en çok 1 bekleyen çıkış; gönderim son anı = `slot - (presentationDeadline + 1 ms)`; deadline bilinmiyorsa `slot - P`. En erken yuva için son an zaten geçmiş sayılır (hemen bırakılır), yalnızca >=1 P ilerideki yuvalar bekletilir. Zaten bırakılmış yuvaya düşen daha yeni kare atılır (geri alınamaz) -> `slot_dups`.
  - Son yuva sınırı: `slot <= en_erken + P` (ızgaraya hizalı olduğundan "pay" P'nin altında bir fark yaratmaz, eklenmedi); aşan kare önceki yuvayı paylaşır (`collided`+`lateDrop`). `D` tavanı 1,5 P (fazla içerikte P + margin).
  - Faz: VsyncClock görüntü-zamanında çalışır (`Choreographer - appVsyncOffset`); hedef ve en erken yuva `presentationDeadline` içerir; tek `Grid` anlık görüntüsü; panel değişimi `epoch` ile (ekran dinleyicisi yetkili; yalnızca örneklerden, tam kat aralık için 12 örnek, diğeri 4). Boşta >1 sn yeniden çapa (feedback seviyesi korunur).
  - Yumuşatma: taban `b` +50/-200 us/kare, `D` +1000/-100 us/kare.
  - **`MainActivity.kt` kart dosyalarında yok, dokunmadım.** Bağlantı orkestratörde yapılmalı: (1) `vsync.setDisplayTiming(display.appVsyncOffsetNanos, display.presentationDeadlineNanos)` (her iki `VsyncClock` için, ekran değişiminde tekrar), (2) `--ei inflight N` -> `renderer.maxInFlight = N` (varsayılan 0 = sınırsız), (3) isteğe bağlı `--ei lead_us N` -> `vsync.leadOverrideNs = N*1000`. Bunlar olmadan varsayılanlar: offset 0, deadline 0 (bekleme kipi P), lead P/2, inflight sınırsız.
  - İstatistik: `MB/render ev=present slot_dups late_drops in_codec_p95 lead_ms d_us inflight_limit` satırı `VideoRenderer.onSkipWindow` içinden, MainActivity'nin mevcut saniyelik çağrısıyla yazılıyor (`MB/render stats` satırı ve overlay değişmedi).
  - GL yolu: `VsyncClock` değişiklikleri (Grid/epoch) ona da uygulanır; SlotReleaser yalnızca MediaCodec yüzey yolunu ilgilendirir.
- **Test edilmeyenler / cihazda doğrulanacaklar:** hepsi (cihaza dokunulmadı). Bakılacaklar: 120 Hz'te `SF --latency` 16,7 ms tekrar oranı (hedef < %2), 60 Hz'te 33 ms boşluk; `MB/render ev=present` içinde `slot_dups`/`late_drops` makul mu (yüksek `late_drops` = `D` çok küçük ya da sınır çok sıkı); gecikme (`pace_ms`) +1 P'yi aşmamalı. `inflight` 2/3/4 denemesi: dikkat, `FrameQueue` 2'den fazla bekleyen karede keyframe istiyor; sınır düşükse kuyruk taşıp keyframe döngüsü yaratabilir (varsayılan kapalı bu yüzden).
- **Ayarlanacak sabitler (cihaz ölçümüne göre):** `VideoRenderer.DISPATCH_MARGIN_NS` (1 ms; deadline bilinmiyorsa bekletme payı P), `VsyncClock.leadOverrideNs` (varsayılan P/2; SF'ye göre kalibre), `AdaptivePacer.D_SLEW_UP_NS/D_SLEW_DOWN_NS`, `BASE_SLEW_UP_NS/DOWN_NS`, `MAX_D_HALF_PERIODS` (3), `MARGIN_NS` (0,5 ms), `PERCENTILE` (99), `IDLE_REANCHOR_NS`, `VsyncClock.RESEED_AFTER_MULTIPLE` (12), `InFlightGauge.STALL_NS`.
- **Açık sorular:** (a) `FrameQueue` taşma kuralı (host T-058 ile ilgili) inflight sınırıyla etkileşir. (b) `presentationDeadlineNanos` cihazda gerçekte kaç ms; HarmonyOS'ta 0 dönebilir, o halde P kipi kullanılır. (c) Bekleyen çıkış bekletilirken codec çıkış arabelleği sayısı (genelde 4-8) sınırı: 1 tutulur, sorun beklenmiyor.

### Cihaz ayarı sonrası güncelleme (orkestratör ölçümü)

- Öncü (lead) varsayılanı **0,72 P** (120 Hz'te 6,0 ms): tek adlandırılmış sabit `VsyncClock.FAST_PANEL_LEAD_FRACTION`; yalnızca periyot < 11,2 ms (>= ~90 Hz) panelde. 60 Hz **P/2 kalır**: ölçülmedi, 0,72 P = 12 ms orada kanıtsız ve SF ufkuna fazla yakın olur; kesirli biçimin 60 Hz'te doğru olduğu gösterilmedi. `--ei lead_us` her iki durumda geçersiz kılar.
- Ölçüm: baz main %11,5; P/2 %6,4; 2 ms %13,0; 5 ms %5,5; 6 ms %0,2/1,1/7,1; 6,5 ms %4,1; 7,5 ms %4,8; inflight 3 -> %6,3, 4 -> %8,6 (kazanç yok, varsayılan 0 kalır).
- **Açık soru:** 6 ms'te koşudan koşuya büyük fark (0,2 -> 7,1) Mac ile tablet 120 Hz saatleri arasında yavaş faz kaymasına işaret ediyor. Fikirler: yakalama zamanı ile vsync fazını (capture mod P) izleyip kaymayı ölçmek ve öncüyü ±1 ms içinde yavaşça ayarlamak (tekrar oranı pencerelerine göre geri besleme, `onSkipWindow` gibi); host yakalama kadansını tablet vsync'ine kilitlemek (T-058/T-059 tarafı); `lead` taramasını daha uzun pencerelerle (60 sn+) tekrarlamak.

## Orkestratör notu (merge, 2026-10-01)

- Cihazda ölçüldü (NOTES ~03:00): 120 Hz'te tekrar %11,5 → ortalama ~%3 (öncü 6 ms). Codex turu yapılmadı (video sunumu). Faz kayması açık soru.
