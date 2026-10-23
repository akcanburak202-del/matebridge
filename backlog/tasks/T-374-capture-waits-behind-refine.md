---
id: T-374
title: Host — durağan ekran iyileştirme (refine) treni sırasında gelen gerçek kare 10–12 ms bekliyor (Oyun modunda masaüstü imleç takılması)
status: review
phase: 7
owner: mac-host-dev
depends_on: [T-370]
decisions: []
files:
  - host-mac/Sources/MateBridgeCore/Video/FrameGate.swift
  - host-mac/Sources/MateBridgeCore/Video/EncoderSubmitOrder.swift
  - host-mac/Sources/MateBridgeCore/Video/StillRefine.swift
  - host-mac/Sources/MateBridgeHost/Video/HEVCEncoder.swift
  - host-mac/Tests/MateBridgeCoreTests/
  - docs/LOGGING.md
  - backlog/tasks/T-374-capture-waits-behind-refine.md
---

## Amaç

Kullanıcı 2026-10-23 ~20:35: "dock'ta imleç takılması gene oldu" (host 40dac735, Oyun 60, 1848, Wi-Fi; Oyun'da yerel imleç kapalı, `cursor_prefs enabled=0`, imleç videoda). host.log (mono 119582–119660 s): seyrek yakalama (cap_fps 1–11) saniyelerinde `gate_wait` p50 ~11,5 ms, p95 ~12,7 ms; aynı saniyelerde `ev=refine` trenleri (çoğu `reason=max_bytes`, 13 kare/197 ms, ~20 KB/kare). Video srtt 20–65 ms (akşamın başında 8–12). Seyrek yakalama saniyelerinde p50 ≥ 5 ms oranı: 40dac735 %26 (n=47), b14c48d1 %6, 67553f99 %2; n küçük.

Şüpheli iki yol (ayırt edilecek):
1. **Kapı ızgarası:** refine kareleri sentetik, `bypassGate: false`, ızgarayı ilerletir (`HEVCEncoder.resubmitLast`). Hareket başlayınca gelen gerçek kare treni iptal eder (`noteCapture`) ama son refine karesinin açtığı yuvayı bekler (≤ 1 aralık). T-253'ten beri olabilir.
2. **T-370 geri basıncı:** kodlayıcıdaki/kuyruktaki refine kareleri `inFlight + queued >= 2` yapınca gerçek kare tutuluyor; Wi-Fi yavaşken (srtt 30+) daha uzun.

## Kabul

1. Önce kırmızı test(ler): 60 fps, refine treni çalışırken gerçek yakalama gelir (a) kodlayıcı boş, (b) kuyrukta 1–2 refine karesi + yavaş aktarım. Beklenti: gerçek kare kapıda ≤ 1 ms bekler; geri basınçta refine kareleri gerçek kareye öncelik vermez (en az: tren hemen biter, yeni refine karesi kodlayıcıya girmez; kuyruktaki refine karesi zinciri bozmadan bırakılamıyorsa gerçek kare en fazla bir refine yazımı kadar bekler). Hangi yolun cihaz logunu açıkladığı Handoff'ta.
2. T-253 (refine), T-065/T-066/T-072, T-365, T-368, T-370 testleri geçer; refine treninin kendisi akış hızında kalır (patlama yok).
3. Gerekirse LOGGING.md.
4. `./scripts/check.sh` (Android T-367 hariç). Çalışan uygulamaya dokunma, Mac'te pencere açma, cihaz testi yok.

## Plan

1. Kirmizi testler (RefineCaptureWaitTests). 2. Yol 1: FramePacer, izgara yuvasini sentetik kare koyduysa gercek kareyi yargilamadan once izgarayi sifirlar. 3. Yol 2: sentetik kare asagi akisa yalniz yuk 0 iken girer; gercek kare icin hep yer kalir.

## Handoff
- Dal: task/T-374-capture-waits-behind-refine. Commit SHA: 13fbce3d (kart notu bu commit'e dahil, SHA kendi commit'ini gosterir).
- Dosyalar: MateBridgeCore/Video/FrameGate.swift (`FrameGate.resetGrid`, `FramePacer.syntheticOwnsGate`, `pendingIsSynthetic`), EncoderSubmitOrder.swift (`downstreamHasRoomLocked(synthetic:)`), Tests/.../Video/RefineCaptureWaitTests.swift (yeni), bu kart. HEVCEncoder/StillRefine/LOGGING degismedi (yeni alan yok).
- **Hangi yol cihaz logunu aciklar (host.1.log, mono 119582-119660 s; ham satir repoda yok): Yol 1 (kapi izgarasi).** Kanit: (a) streamFps 60, `decimated=0` => decimating degil, tolerans yarim aralik (8,3 ms). Refine kareleri izgara yuvasina tolerans kadar erken biner; zincir (kodlama ~4 ms) bu yuzden kare basina ~12,5 ms kapi bekler, `gate_wait` p50/p95 ~11,6/12,7 (13 refine karesi/s). (b) `ev=latency` refine karelerini de sayiyor: `cap_fps=0` saniyelerinde `frames=13`, `gate_wait` p50 11,6; yani "seyrek yakalama saniyelerinde p50 >= 5 ms" olcusunun buyuk kismi refine karelerinin kendi (zararsiz, hizlari sinirli) beklemesi. (c) Treni iptal eden gercek kare, son refine karesinin biraktigi yuvayi bekler (yuva = refine gonderimi + tolerans + aralik): ilk gercek kare ~ aralik - d (14-16 ms). Logda tren iptalinden sonraki saniye `gate_wait` p50/p95 14,6/16,4 ms, `overwritten=2`; kapi tek basina en cok yarim aralik degil bir aralik bekletebilir, test 11,7 ms uretti. Yol 2 (T-370 geri basinci) bu logda gerekli degil ama kod yolu gercek (yavas aktarimda srtt 56 ms, unacked 85 KB: refine karesi onceki refine ciktisinin ustune girip yuk=kapasite yapabilir; kirmizi test gosterdi, kapatildi). Cihazda ikisini ayiran dogrudan log yok (`backPressureHolds` loga yazilmiyor).
- **Kirmizi cikti (duzeltme oncesi):** testRealCaptureAfterRefineTrainDoesNotWaitForTheGrid: `("11700") is greater than ("1000") - real capture waited 11700 us behind the refine train`; testRefineFrameDoesNotUseTheBudgetARealCaptureNeeds: `XCTAssertTrue failed - real capture reached the encoder at once, encoded: [0, 1, 2]` (gercek kare 3 tutuldu). Koruma testleri: refine treni akis hizinda (55..64 fps), sonraki gercek kareler akis hizini asmaz.
- Duzeltme sonrasi: swift test 720 test, 0 hata. check.sh: host/protokol/kit OK; yalniz gradle (client-android) kirmizi = T-367 bilinen flaky, Android'e dokunulmadi.
- Varsayimlar: tren sonrasi ilk gercek kare izgarayi yeniden demirler; en cok bir fazladan kare (trenin sonuncusu) bir aralik icinde gecer. Yol 2: refine kareleri artik yalniz asagi akis tamamen bosken girer; yavas aktarimda tren daha erken `timeout`/`queue_busy` ile bitebilir (kasitli).
- Cihazda dogrulanacak: Oyun 60'ta `cap_fps` > 0 ve refine'siz saniyelerde tren iptali sonrasi `gate_wait` p95 (beklenti < 2 ms); `ev=latency` refine karelerini de sayar, p50 yine yukari cekilebilir; Wi-Fi yavasken `reason=timeout/queue_busy` orani artmadi mi; tren kendi hizinda (13 kare / ~200 ms).

## Open questions
