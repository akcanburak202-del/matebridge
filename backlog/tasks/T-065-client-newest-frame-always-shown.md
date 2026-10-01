---
id: T-065
title: Tablet — en yeni kare her zaman gösterilir (seyrek karelerde faz kilidi kareyi atıyor; yazarken donma)
status: review
phase: 5
owner: android-client-dev
depends_on: [T-057, T-060, T-061]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/
  - client-android/app/src/test/
  - backlog/tasks/T-065-client-newest-frame-always-shown.md
---

## Amaç

T-062 teşhisi (NOTES 2026-10-01 sabah, T-062 kartı). Kullanıcı: yazarken ekran donuyor, imleç oynayınca yazılanlar geliyor; imlecin ilk hareketinde takılma. Tablet T-057 öncesine (`98b325e`) geri alınınca geçti.

**Kök neden (birim simülasyonla doğrulandı):** panel 60 Hz (boşta/yazarken), kareler 100–600 ms arayla tek tek geliyor. `AdaptivePacer.scheduleLocked` önceki kilit slotundan `k = round(dCapture / P)` ile tahmin yapıyor; host yakalaması 120 Hz ızgarasında olduğundan aralık yarım panel periyodu kayabiliyor → slot `earliest`'ten önce çıkıyor → `lateDrop`, karar `slotNs = previous` → `SlotReleaser.submit` bu slot zaten bırakılmış olduğu için kareyi **atıyor**. Ardından yeni kare gelmediğinden içerik bir sonraki değişikliğe kadar ekranda yok. Hatalı tahminli kilit `REPHASE_FRAMES = 30` kare boyunca sürüyor → hareketin başında art arda atma (imleç takılması). Simülasyon (pacer + SlotReleaser uçtan uca, ölçek: 300 kare): panel 60, aralık 100–600 ms → **126/300 kare hiç gösterilmedi**; panel 120 ya da aralık > 1 s (yeniden çapalama) → 0. Simülasyon kaynağı: orkestratörün scratch'indeki `ScratchSparseTest.kt` (aşağıda özet; testi kendin yaz).

## Kabul kriterleri

- [ ] **Değişmez (invariant):** çözülmüş bir kare, yalnızca daha yeni bir kare onun yerini aldığında atılabilir. En yeni kare her zaman (sınırlı süre içinde, ≤ 2 panel periyodu + sunum son anı) `releaseOutputBuffer(idx, ts)` ile bırakılır. `SlotReleaser`: slotu zaten bırakılmış bir kare atılmaz; bırakılmış slottan sonraki slota (bekleyen, değiştirilebilir) taşınır, zaman damgası/son anı buna göre. `slot_dups` sayacı anlamını korur.
- [ ] **Faz kilidi yalnızca sürekli akışta tahmin yapar:** önceki kareden bu yana yakalama aralığı belirgin biçimde büyükse (ör. > 2 içerik aralığı ya da > 3 panel periyodu; seçimini gerekçelendir) kilit yeniden edinilir (`acquire`), `rephases` sayılmaz. Uzun boşluktan sonraki ilk kare `earliest`'e (ya da merkezlenmiş noktaya) gider, atılmaz.
- [ ] Kilitli ve kilitsiz yolda geç kare (`lateDrop`) ancak ardından gelen bir karenin yerini alması mümkünse düşer; değilse değişmez gereği gösterilir.
- [ ] **Regresyon testleri (önce kırmızı, sonra yeşil):** pacer + `SlotReleaser` birlikte, sahte sink, zaman ilerletmeli:
  - panel 60 ve 120 Hz; host yakalama ızgarası 120 Hz; akış 60/120; aralıklar 100–600 ms, 20–60 ms, 1,1–3 s → **gösterilmeyen son kare = 0** (her karenin ya bırakıldığı ya da daha yeni bir kare tarafından değiştirildiği; bir aralığın son karesi daima bırakılır).
  - Tek kare: uzun boşluktan sonra tek kare → ≤ 2 periyot içinde bırakılır.
  - Panel 60 → 120 geçişi sırasında (epoch değişimi) seyrek ve sürekli kareler: kayıp son kare yok.
  - Mevcut T-057/T-060/T-061 testleri (sürekli akışta yuva başına tek bırakma, faz kilidi tekrar oranları) geçmeye devam eder; davranış değişirse gerekçeyle güncelle.
- [ ] `GlPresenter` yolunda aynı tür "ardılsız atma" var mı bak; varsa aynı değişmezi uygula ya da *Açık sorular*a yaz (GL yolu varsayılan değil).
- [ ] `./scripts/check.sh` geçiyor.

## Kapsam dışı

- Öncü (6 ms), saat kayması, host tarafı (T-066).

## Plan

1. `SlotReleaser.submit` yeni `periodNs` parametresi alir: birakilmis slota (<= releasedSlot) dusen kare atilmaz, `releasedSlot + period`'a tasinir (slot, renderNs, deadline ayni miktarda kayar), normal kurallara girer; `slot_dups` yine sayilir.
2. `AdaptivePacer.scheduleLocked`: onceki yakalamadan bu yana bosluk > 3 panel periyodu (`LOCK_GAP_PERIODS`) ise kilit tahmin yapmaz, `acquire()` ile yeniden edinilir (rephase sayilmaz); edinilen kare asla lateDrop olmaz.
3. Test: pacer + SlotReleaser uctan uca (`NewestFrameShownTest`).

## Handoff

- **Commit:** bkz. branch task/T-065-client-newest-frame (`T-065: ...`)
- **Dokunulan dosyalar:** video/SlotReleaser.kt, video/AdaptivePacer.kt, video/VideoRenderer.kt (tek satir: periodNs gecirilir), test/.../NewestFrameShownTest.kt (yeni), PresentationSchedulingTest.kt (SlotReleaserTest guncellendi), bu kart.
- **Varsayımlar:** Esik 3 panel periyodu: kilitlenebilir icerik araligi ~1 periyot (+ seyreltilmis 2) ve jitter bunun altinda; bosta/seyrek guncelleme > 50 ms (60 Hz) / 25 ms (120 Hz). Tasinan kare `releasedSlot + period`'a gider; slot gecmiste kalabilir (renderNs gecmis = bir sonraki vsync'te hemen sunulur), <= 2 periyot siniri korunur. Mevcut T-057/T-060/T-061 testleri degismeden gecti (yalniz submit cagrilarina periodNs eklendi; asilmis-slot testi yeni davranisa gore guncellendi).
- **Test edilmeyenler / cihazda doğrulanacaklar:** Cihaz yok. Tablette: Mac'te tek tus/tek kare degisikligi (bosta, 60 Hz) sonrasi `screencap` ile son karenin gorundugu; yazarken donma yok, imlec ilk hareketinde takilma yok; STATS'ta `slot_dups` seyrek akista artabilir (tasinan kareler); surekli 60/120 akista pacing metrikleri (skip %, rephases) onceki gibi. GlPresenter yolunda ayri ardilsiz-atma yok (slot/releaser kullanmiyor); degistirilmedi.
- **Açık sorular:** Kirmizi-once dogrulamasi arac kisiti nedeniyle elle yapilmadi; scratch simulasyonu eski kodda 126/300 kayip gosteriyordu, yeni testler (ayni senaryolar) yesil.
