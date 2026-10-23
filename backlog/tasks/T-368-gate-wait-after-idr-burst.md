---
id: T-368
title: Host — T-365 sonrası da IDR patlamasından sonra gate_wait 8–9 ms'de onlarca saniye kalıyor
status: done
phase: 7
owner: mac-host-dev
depends_on: [T-365]
decisions: []
files:
  - host-mac/Sources/MateBridgeCore/Video/FrameGate.swift
  - host-mac/Sources/MateBridgeCore/Video/EncoderSubmitOrder.swift
  - host-mac/Sources/MateBridgeHost/Video/ScreenCapture.swift
  - host-mac/Tests/MateBridgeCoreTests/
  - docs/LOGGING.md
  - backlog/tasks/T-368-gate-wait-after-idr-burst.md
---

## Amaç

Kanıt: NOTES 2026-10-23 akşam ("knob kapalı oyun oturumu"). Host b14c48d1 (T-365 dahil), Oyun 60, 60 Mbps, Wi-Fi. Her Wi-Fi kaybı → kuyruk düşüşü → zorunlu IDR (490–884 KB) olayından sonra `video ev=latency gate_wait` p50 0,1 → 8–9,5 ms'ye sıçrıyor ve 10–95 sn öyle kalıyor (1212 pencerenin 470'i). `slot_wait`, `gpu` ~0; `hold_ms` ≈ `gate_wait`. Bu sürelerde uçtan uca `cap_dec_ms` ~13 → ~21 ms. T-365 birim testindeki senaryo (tek geç gönderim) cihazdaki durumu kapsamıyor.

Örnek olay (host.log mono ms, `~/Library/Logs/MateBridge/host.log` ve `host.1.log`; salt okunur, depoya log girmez): 114726755 retx 1 → 114727347 `overwritten=1 queue_drops=12`, 114728347 `overwritten=3 queue_drops=9`, IDR 3+3+1 → 114729348 `gate_wait` p50 8,0 ms, 114777'ye kadar yüksek. Diğer başlangıçlar: 114092, 114213, 114359, 114499, 114694, 114988, 115044, 115131.

## Kabul

1. **Önce kırmızı test** (saf, `FrameGate`/`FramePacer` ya da gerçek çağıran sırası neyse o seviyede): cihazdaki olay dizisi modellenir: kodlayıcı/gönderici birkaç yüz ms takılır, bu sırada kareler `overwritten`/düşer, bekleyen kare(ler) geç gönderilir, sonra kaynak eski kadansla devam eder. Beklenti: olaydan sonra en geç birkaç kare içinde kapı beklemesi ≤ 1 ms. Bugünkü kodda kırmızı (Handoff'ta çıktı). Modelin cihaz logu ile uyumlu olduğu (hangi yol yeniden demirliyor: `takePending`, sentetik kare, bypass, decimation, `accept`'in kredi tavanı) Handoff'ta gerekçelenir; gerekirse geçici `[DEBUG-t368]` log yerine gerçek host.log satırlarından çıkarım yapılır.
2. Düzeltme T-365 kabul 2'deki kuralları korur (uzun dönem hız ≤ stream fps, aralıkta ≤ 2 kare, decimation davranışı, T-065/T-066).
3. T-365 testleri ve mevcut FrameGate/FramePacer testleri geçer.
4. LOGGING.md gerekirse bir cümle.
5. `./scripts/check.sh` geçer (Android timing testleri T-367; kırmızıysa Handoff'ta belirt).
6. Çalışan host uygulamasına dokunulmaz, Mac'te pencere açılmaz, cihaz testi yapılmaz (orkestratör yapar).

## Plan

Kök neden (host.log'dan, kod okumasıyla): olay penceresinde `enc_in=enc_out=60`, `slot_wait`~0, yani kodlayıcı takılmadı; T-365 senaryosu (geç gönderim) bu olayda yok. Olan: ağ kuyruğu düşüşü -> `requestKeyframe(resubmitNow:)` -> `HEVCEncoder.resubmitLast` son tamponu `bypassGate: true`, damga `now + lead` ile ek kare olarak sunar (IDR 3+3+1 = 7 kez). `FramePacer.offer` bunu `submitted()` ile kabul edip `gate.accept(now)` çağırıyor: ızgara kaynak kadansının bir aralık önüne geçiyor, sonraki her gerçek kare yarım aralık (8,3 ms) bekliyor; ofset her kare bir aralık ilerleyip bir aralık sonra geldiği için sabit kalır, yalnız saat kaymasıyla erir (log: 8-9,5 ms, 10-95 sn). Ayrıca `noteLag` bypass karesinin `now - (now+lead)` negatif gecikmesiyle T-365 tabanını bozuyor.

Düzeltme (`FramePacer`): bypass kareleri ızgarayı ilerletmez (ek kare, hız sınırından muaf; önceden de bekletilmiyordu), `lastSubmittedPtsUs` yine ilerler, `noteLag`'a girmez. Gerçek kareler için hız sınırı ve T-072/T-065/T-066 kuralları aynı. Decimation: bypass zaten ayrı yoldu; artık pts-ızgarasına `now` ile accept de yazmıyor.

## Handoff

- Dal: task/T-368-gate-wait-after-idr-burst. Commit SHA: 40ba99f0 (kod + test + LOGGING).
- Dosyalar: host-mac/Sources/MateBridgeCore/Video/FrameGate.swift, host-mac/Tests/MateBridgeCoreTests/Video/FrameGateIdrBurstTests.swift (yeni), docs/LOGGING.md, bu kart.
- **Kırmızı çıktı (düzeltme öncesi, yeni testler):** testRealFramesDoNotWaitAfterAnIdrBurst: son 60 gerçek karede en yüksek kapı beklemesi 9160 us, dizi [8454, 8788, 9122, ...] (> 1000); testSingleIdrResubmissionAtAnyPhaseKeepsWaitsLow: ofset 1000/4000/7000/10000 us'de 9080 us; testIdrBurstWithClockSkewKeepsWaitsLow: +50 ppm 8977, -50 ppm 9297; testBypassFrameDoesNotMoveGridOrLagBaseline: nextSlot 33332 != 16666. testRealFrameRateStaysCapped kırmızı değil (hız sınırı korunuyor). Cihaz logundaki 8-9,5 ms ile aynı büyüklük.
- Düzeltme sonrası: swift test 695 test, 0 hata. Mevcut FrameGate/FramePacer/T-365 testlerinin beklentisi değişmedi.
- Model-log uyumu: olay penceresinde enc_in=enc_out=60, overwritten 1-3 (kuyruk düşüşü ağ tarafında), IDR 3+3+1; yol `takePending`/sentetik/decimation değil, `offer(bypassGate:true)`. Doğrudan cihaz izi yok (log yalnız saniyelik ev=latency).
- Varsayım: bypass kareleri hız sınırından muaf kalır (tasarım gereği; kuyruk düşüşü başına birkaç IDR).
- Cihazda doğrulanacak: Wi-Fi kaybı/IDR patlamasından sonra Oyun 60 `gate_wait` p50 0,1 ms'de kalıyor mu (T-366 dummynet enjektörü ile önce/sonra); IDR yeniden gönderimi sırasında tablette kare sırası/gecikme değişikliği yok mu. check.sh: host swift build+test OK; gradle (client-android) kırmızı: DecoderWaitTest ve OutputParkTest (T-367 flaky zamanlama testleri, Android'e dokunulmadı).

## Open questions
