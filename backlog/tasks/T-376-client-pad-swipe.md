---
id: T-376
title: İstemci — touchpad'de üç parmak kaydırmayı tanı, PAD_SWIPE (0x18) gönder
status: todo
phase: 7
owner: android-client-dev
depends_on: []
decisions: [0043]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/protocol/Messages.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/protocol/Codec.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/input/RelPointerTracker.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/input/Model.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/input/InputCapture.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/input/MotionEventAdapter.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/
  - docs/LOGGING.md
  - backlog/tasks/T-376-client-pad-swipe.md
---

## Amaç

Karar 0043: Glide Keyboard touchpad'inde (pointer capture, `RelPointerTracker.onPad`) üç parmakla kaydırma tanınsın ve `PAD_SWIPE` gönderilsin. Sözleşme: PROTOCOL.md §4 `0x18 PAD_SWIPE` (istemci kuralları). Fixture'lar: `pad_swipe_up`, `pad_swipe_left`. Bugün üç parmak `locked` ve hiçbir şey göndermiyor; o davranış (açık SCROLL/PINCH'in ENDED ile kapanması dahil) korunur.

## Kabul

1. `PadSwipe` mesajı, kodlama/çözme, fixture testleri bayt bayt.
2. Tanıma: hareket boyunca en çok üç parmak varken (`maxCount == 3`, dört parmak hiçbir şey göndermez), üç parmağın ortak (ağırlık merkezi) yolu baskın eksende eşiği geçince **bir kez** gönderilir, parmakların kalkmasını beklemeden. Başlangıç değerleri `PadTuning`'de: eşik pad boyunun ~%12'si, baskın eksen diğerinin ≥ 2 katı. Üçüncü parmak indikten sonra kısa bir oturma süresi (iki parmaktaki `SETTLE_MS` gibi) uygulanabilir. Fiziksel tık basılıyken gönderilmez. Bir hareket (ilk iniş → son kalkış) en çok bir PAD_SWIPE. Üç parmaktan iki/bir parmağa düşünce hareket bitene kadar kaydırma/imleç yeniden başlamaz (bugünkü `locked`).
3. Yön: ekran koordinatı; y aşağı artar → parmaklar yukarı = `UP`. Yön ters çıkarsa bu cihazda ham koordinatlar (NOTES T-003: x ~174–1734, y ~97–1624) ile kontrol edilir.
4. Birim testleri: dört yön; eşik altı hareket göndermez; çapraz (baskın değil) göndermez; tek hareketin ikinci kez eşiği geçmesi ikinci mesaj üretmez; tıkla sürükleme göndermez; iki parmak kaydırma sürerken üçüncü parmak → SCROLL ENDED sonra (eşik geçilince) PAD_SWIPE; dört parmak göndermez; üç parmak dokunuşu (hareketsiz) bugünkü davranışı değiştirmez.
5. Debug logu: `ev=pad_swipe dir=…` (info) ve debug düzeyinde üç parmak hareketinin bitişinde ortak yol (dx, dy, pad birimi). Cihazda HarmonyOS'un üç parmak olayını uygulamaya iletip iletmediği bu logla görülür. LOGGING.md güncellenir.
6. `./scripts/check.sh` geçer (T-367 bilinen flaky testleri hariç, Handoff'ta belirt). Cihaz testi yok, adb kurulum yok; orkestratör yapar.

## Plan

## Handoff

## Open questions
