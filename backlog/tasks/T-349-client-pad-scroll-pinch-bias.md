---
id: T-349
title: İstemci — trackpad'de iki parmak kaydırma bazen pinch sanılıyor (kaydırma lehine sınıflandırma)
status: todo
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

## Handoff

## Open questions
