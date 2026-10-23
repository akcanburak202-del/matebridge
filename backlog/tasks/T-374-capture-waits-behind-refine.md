---
id: T-374
title: Host — durağan ekran iyileştirme (refine) treni sırasında gelen gerçek kare 10–12 ms bekliyor (Oyun modunda masaüstü imleç takılması)
status: todo
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

(ajan yazar)

## Handoff

## Open questions
