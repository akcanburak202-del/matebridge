---
id: T-349
title: İstemci — trackpad'de iki parmak kaydırma bazen pinch sanılıyor (kaydırma lehine sınıflandırma)
status: review
phase: 7
owner: android-client-dev
depends_on: []
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/input/TwoFingerClassifier.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/input/RelPointerTracker.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/input/
  - backlog/tasks/T-349-client-pad-scroll-pinch-bias.md
---

## Amaç

Kullanıcı (2026-10-17): klavye trackpad'inde iki parmakla kaydırırken hareket bazen kaydırma, bazen pinch (yakınlaştırma) olarak algılanıyor. Tutarlı olmalı: bilinçli bir açma/kapama dışında her iki parmak hareketi kaydırma olmalı.

## Teşhis (orkestratör, kod okuması)

`TwoFingerClassifier.classify` karar eşikleri pad'de pinch lehine dengesiz:
- Pinch: `|d - d0| / max(d0, extent*0.05) >= 0.06`. Yan yana iki parmak pad genişliğinin ~%15–20'si aralıkta, yani pinch kararı için mutlak olarak ~extent*%1 mesafe değişimi yetiyor.
- Kaydırma: ortak hareket > `extent * SLOP_FRAC` (= extent*%2).
- Kaydırma sırasında parmaklar doğal olarak birkaç mm açılır/kapanır. İkinci parmak inerken temas noktaları da oturur (taban `resetTwoBaseline` ikinci parmak indiği anda alınıyor). Bu yüzden hangi eşik önce aşılırsa o karar veriliyor.

## Kapsam

1. **Pad'de pinch için mutlak alt sınır:** mesafe değişimi hem göreli eşiği hem de kaydırma eşiğinin bir katını (öneri 2×slop) aşmadan PINCH denmez. Aynı karede ikisi birden aşılınca kaydırma lehine karar verilir (bugünkü `dd >= 2*common` kuralını gözden geçir; pinch için baskınlık daha net olmalı).
2. **Yerleşme süresi:** ikinci parmak indikten sonraki kısa bir pencerede (öneri ~60 ms, sabit olarak) karar verilmez; pencere sonunda taban (`twoD0`, centroid) yeniden alınır. Bu pencerede kaydırma gecikmesi hissedilmemeli: pencere içindeki ortak hareket, karar sonrası ilk CHANGED ile gönderilsin (bugünkü birikimli davranış gibi) ya da pencere dışında kaybolmasın.
3. Dokunmatik ekran da `TwoFingerClassifier` kullanıyor. Ekranda davranış değişmemeli (orada parmak aralığı ve ölçek farklı). Değişikliği pad'e özgü parametrelerle yap (örn. classify'a mutlak alt sınır parametresi; ekran çağrısı bugünkü değeri verir). Ekran testleri değişmeden geçmeli.
4. Gerçek bir pinch (parmakları belirgin açıp kapama) yine pinch olmalı. Mac'te pinch yakınlaştırma çalışmaya devam etmeli.
5. Tel biçimi ve host değişmez.

## Kabul

- Birim testleri (sentetik pad dizileri):
  - Kaydırma sırasında parmak aralığı ±%10 salınıyor ve ikinci parmak inerken birkaç birim kayıyor → her zaman SCROLL.
  - Belirgin pinch (aralık %25+ değişiyor, centroid neredeyse sabit) → PINCH.
  - Yerleşme penceresindeki hareket kaydırmada kaybolmuyor.
  - Mevcut `PinchTest`, `FingerPolicyTest`, dokunmatik ekran testleri değişmeden geçer (eşik değişikliği gerekiyorsa gerekçesi Handoff'ta).
- `./scripts/check.sh` geçer. Cihaz testi orkestratörde.

## Plan

1. `classify` gets `pinchMinAbs` (default 0, screen unchanged) and `dominance` (default 2). Pad passes 2 x slop (extent 4 %) and 3.
2. Pad tracker: 60 ms settle window after the 2nd finger lands. In it no PINCH can be decided, the distance baseline follows the contacts, a SCROLL can still be decided at once (no latency; motion accumulates in twoX/twoY as before).
3. Tests: new `TwoFingerPadBiasTest`; pad pinch tests in `PinchTest` moved past the window.

## Handoff

- Commit: T-349 commit on `task/T-349-pad-scroll-pinch-bias`.
- Files: TwoFingerClassifier.kt, RelPointerTracker.kt (PadTuning: PINCH_MIN_SLOPS=2, PINCH_DOMINANCE=3, SETTLE_MS=60), PinchTest.kt (timestamps only), new TwoFingerPadBiasTest.kt.
- Thresholds: pinch needs dd >= 2*slop (4 % of pad extent; normal two-finger spacing is 15-20 %, so roughly a 20-25 % spacing change) AND the relative 6 %; same-frame crossing needs dd >= 3x centroid travel (was 2x). Settle 60 ms as suggested.
- Deviation from card: the window blocks only PINCH, not SCROLL, so scroll start has no added latency and window motion cannot be lost. The distance baseline follows the contacts inside the window instead of a single retake at its end (a single retake would swallow a fast pinch whose first frame lands right after the window).
- Existing tests: touchscreen tests untouched. Five pad-pinch tests in PinchTest only had MOVE timestamps shifted from 20-50 ms to 70-120 ms (otherwise inside the 60 ms window). Scroll tests unchanged.
- Not tested: real device. Check on tablet: two-finger scroll on the keyboard pad many times never zooms; a deliberate pinch (clear spread/close) still zooms on the Mac; a very small pinch now needs a bit more travel.

## Open questions

(none)
