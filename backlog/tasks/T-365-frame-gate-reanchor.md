---
id: T-365
title: Host — FrameGate geç kareden sonra yeniden demirlenince zamanında gelen kareleri dakikalarca bekletiyor
status: review
phase: 7
owner: mac-host-dev
depends_on: []
decisions: []
files:
  - host-mac/Sources/MateBridgeCore/Video/FrameGate.swift
  - host-mac/Tests/MateBridgeCoreTests/
  - docs/LOGGING.md
  - backlog/tasks/T-365-frame-gate-reanchor.md
---

## Amaç

Kanıt: NOTES 2026-10-23 öğleden sonra ("30 Mbps neden kötü göründü"). Oyun 60'ta host `ev=latency` `gate_wait` p50 bir aksaklıktan sonra (kodlayıcı yeniden başlaması, ~32 ms yazma takılması) 0,1 → 8–10 ms'ye sıçrıyor ve ~0,04 ms/s ile eriyerek dakikalarca yüksek kalıyor. `slot_wait` ve `gpu` 0; fark tamamen kapı beklemesi. Bu, bütün modlarda rastgele 0–10 ms fazladan host gecikmesi demek.

Çıkarım (kodla uyumlu, doğrulanacak): `FrameGate.accept` bir kare yuvadan bir aralıktan fazla geç gelince ızgarayı `now + interval`'a demirliyor. Geç kalan kare, kaynak (SCK, sanal ekran vsync'i) kadansına göre geçse, sonraki zamanında gelen kareler yeni yuvadan `geçlik` kadar erken kalıyor; `passThroughToleranceUs` (yarım aralık) bunu karşılamayınca her kare `geçlik − tolerans` kadar bekletiliyor. Izgara her kabulde yalnız bir aralık ilerlediği için ofset ancak sanal ekran saati ile host saati arasındaki kayma hızında eriyor.

## Kabul

1. **Önce kırmızı test** (`FrameGate`/`FramePacer` seviyesinde, saf): 60 fps, kaynak periyodu sabit (ör. 16 667 µs ± küçük kayma) varışlar; araya bir kare 20–30 ms geç girer (sonrakiler eski kadansa döner). Beklenti: geç kareden sonra en geç birkaç kare içinde (kart sayıyı Plan'da belirler) her karenin kapı beklemesi ≤ 1 ms. Bugünkü kodda test kırmızı olmalı (Handoff'ta kırmızı çıktı).
2. Düzeltme kapının amacını korur: uzun dönem gönderim hızı stream fps'i aşmaz; bir aralık içinde en fazla iki kare geçer (T-072 kuralı); decimation kipi (T-058, `setTargetFps` < stream fps) davranışı değişmez; T-065/T-066 kuralı (bir kare yalnız daha yenisi onun yerini alınca düşer) bozulmaz.
3. Mevcut FrameGate/FramePacer testleri geçer; değişen beklentiler Handoff'ta listelenir.
4. Ek testler: kalıcı faz kayması (kaynak saati host saatinden ±50 ppm), idle sonrası yeniden demirleme, burst (iki kare arka arkaya) — hız sınırı korunuyor.
5. LOGGING.md'de `gate_wait` açıklamasına bir cümle (gerekirse).
6. `./scripts/check.sh` geçer.

## Plan

Gerçek neden (kartın çıkarımından rafine): geç olan şey kaynağın kendisi değil, kuyrukta (encoder yuvası dolu) bekleyen karenin **gönderim anı**. Bekleyen kare yuva boşalınca `takePending` ile R anında gider; R > slot + aralık ise `accept` ızgarayı `R + aralık`'a demirler. Kaynak kadansı R'den `off` kadar öncesine hizalı olduğu için sonraki zamanında kareler `off - tolerans` (tolerans = yarım aralık) kadar bekler; ofset ancak saat kaymasıyla erir.

Çözüm: `FramePacer` gerçek karelerin varış gecikmesinin (now - pts) yavaş yükselen minimumunu (`lagBaselineUs`) izler. Gönderimde `phaseCredit = max(0, lag - baseline)` hesaplanır; `FrameGate.accept(nowUs:phaseCreditUs:)` yeniden demirlemede bunu en fazla yarım aralık kadar geri alır: `nextSlot = now + aralık - min(kredi, aralık/2)`. Kredi zaten karenin tolerans olarak kullanabileceği miktarı aşmadığından aralık başına en fazla iki kare ve uzun dönem hız aynı kalır. Sentetik kareler kredi almaz ve taban çizgisini etkilemez. Decimation yolu (pts ızgarası) ve yeniden demirlemeyen accept yolu değişmedi.

Testler (`FrameGateReanchorTests`): 30 ms yuva doluluğu sonrası son 60 karenin kapı beklemesi <= 1 ms; hız sınırı ve "herhangi 3 gönderim >= 1 aralık"; +-50 ppm kayma; idle sonrası; arka arkaya burst; `accept` kredi sınırı.

## Handoff

- Dal: task/T-365-frame-gate-reanchor. Commit SHA: aşağıda (commit sonrası eklendi).
- Dosyalar: host-mac/Sources/MateBridgeCore/Video/FrameGate.swift, host-mac/Tests/MateBridgeCoreTests/Video/FrameGateReanchorTests.swift (yeni), docs/LOGGING.md (gate_wait cümlesi), bu kart.
- **Kırmızı çıktı (düzeltme öncesi, aynı testler):**
  - `testOnTimeFramesDoNotWaitAfterALateSubmit` FAILED: son 60 karede en yüksek kapı beklemesi 5746 us (> 1000).
  - `testPersistentClockSkewKeepsWaitsLowAfterLateSubmit` FAILED: +50 ppm 5643 us, -50 ppm 5967 us.
  - Geçenler (davranış korunuyor): rate cap, idle sonrası, burst. (`accept(phaseCreditUs:)` testi API yokken derlenemeyeceği için kırmızı koşuya dahil edilmedi.)
- Düzeltme sonrası: tüm host testleri geçiyor; mevcut FrameGate/FramePacer testlerinde beklenti değişmedi.
- Varsayım: kartın "kaynak geç geldi" çıkarımı yerine senaryo "bekleyen kare geç gönderildi" olarak modellendi. Sentetik/bypass kareler kredi almaz. Kredi tavanı yarım aralık (60 fps'te 8,3 ms) = tolerans.
- Gerçek donanımda doğrulanacak: Oyun 60'ta ev=latency `gate_wait` p50 bir kodlayıcı yeniden başlaması / yazma takılması sonrası 0,1 ms'de kalıyor mu (eski: 8-10 ms'ye sıçrayıp dakikalarca yüksek).

## Open questions

- Kartın çıkarımındaki "geç gelen kaynak karesi" varyantı (tek kare geç teslim, sonrakiler zamanında) pts sırası nedeniyle bu biçimde oluşamaz (sonraki kare önce gelir, geç olan stale düşer); bu yüzden bekleyen-kare gönderim gecikmesi modellendi. NOTES'taki çıkarım buna göre düzeltilebilir.
