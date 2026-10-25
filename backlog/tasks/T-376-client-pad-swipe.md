---
id: T-376
title: İstemci — touchpad'de üç parmak kaydırmayı tanı, PAD_SWIPE (0x18) gönder
status: review
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

1. `PadSwipe` (0x18) mesajı + Codec (bilinmeyen yön kabul, yok sayma alıcıda); FixtureTest'e iki fixture, CodecRulesTest'e kısa yük ve bilgi amaçlı enum.
2. `RelPointerTracker`: üç parmak varken (n == 3, maxCount == 3) ortak ağırlık merkezi yolu izlenir; üçüncü parmaktan sonra 60 ms oturma (taban parmakları izler); eşik extent*0.12, baskın eksen >= 2x; hareket başına bir kez (`swipeSent`); `clicked` / basılı düğme varken gönderilmez. Mevcut `locked` davranışı ve SCROLL/PINCH ENDED kapanışı değişmedi.
3. Log: `onEvent` geri çağrısı tracker'a verildi (InputCapture'dan); `pad_swipe` ve `pad_swipe3_end`.
4. `PadSwipeTest` ile kabul 4'teki senaryolar. LOGGING.md.

## Handoff

- Commit: 44f7eef5 (branch `task/T-376-client-pad-swipe`, base 2fc62354).
- Dosyalar: `protocol/Messages.kt`, `protocol/Codec.kt`, `input/RelPointerTracker.kt`, `input/InputCapture.kt` (yalnız `onEvent`i tracker'a verir), `PadSwipeTest.kt`, `FixtureTest.kt`, `CodecRulesTest.kt`, `docs/LOGGING.md`. `Model.kt` ve `MotionEventAdapter.kt` değişmedi (gerek olmadı).
- check.sh: Android (gradle) OK, fixtures OK. Swift tarafında `FixtureTests.everyFixtureFileHasATestCase` kırmızı: `pad_swipe_*` fixture'ları için host testi yok. Bu T-375 (host) kapsamı, bu kartta dokunulmadı.
- Varsayımlar: pad Y ekranla aynı yönde (aşağı artar) kabul edildi; ters çıkarsa `swipeStep` içindeki `swipeDy < 0f` işareti çevrilir. Eşik her iki eksen için extent (X aralığı) üzerinden; Y aralığı ayrıca okunmuyor. Çapraz hareket ilk eşikte gönderilmez ama sonra baskın eksene dönerse gönderilebilir (hareket başına yine en çok bir).
- Sapma: debug logu yerine info (`MainActivity` dosya listesinde yok, `onEvent` yalnız info). `pad_swipe3_end` hareket başına bir satır, seyrek.
- Cihazda bakılacak: Glide Keyboard touchpad'inde üç parmakla yukarı/aşağı/yanlara kaydır; `adb logcat -s 'MB:*'` içinde `MB/input ev=pad_swipe3_end` çıkıyor mu (çıkmıyorsa HarmonyOS üç parmağı yutuyor), `dx`/`dy` işaretleri yönle uyuyor mu (parmaklar yukarı = dy negatif, `dir=up`), dört parmakta satır yok, iki parmak kaydırma/pinch bozulmadı, tıklı sürüklemede `sent=0`. Host tarafı (T-375) olmadan Mac'te etki görülmez.
- Test edilmedi: gerçek tablet (hiçbir şey). T-367 flaky testleri bu koşuda kırmızı vermedi.

## Open questions

### Codex düzeltmesi (P2)

`onPad` ayrılan parmağı çıkardıktan sonra n == 3 denetimi yapıyordu; üç parmağın eşiği ilk UP karesinde geçtiği hızlı kaydır-ve-kaldır kayboluyordu. İlk UP karesinin üç teması (ayrılan parmak dahil) artık değerlendirilir; hareket başına en çok bir PAD_SWIPE. Regresyon testi: `fastSwipeAndLiftIsRecognizedOnTheFirstUpFrame`. Düzeltme commit'i bu satırın hemen ardındaki SHA (bkz. git log).
