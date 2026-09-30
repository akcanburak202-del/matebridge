---
id: T-037
title: Tablet — iki parmakla yakınlaştırma (dokunmatik ekran ve touchpad) → PINCH
status: done
phase: 3
owner: android-client-dev
depends_on: [T-034, T-035]
decisions: [0009]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/protocol/
  - client-android/app/src/main/kotlin/dev/matebridge/client/input/
  - client-android/app/src/test/kotlin/dev/matebridge/client/
  - backlog/tasks/T-037-client-pinch.md
---

## Amaç

PROTOCOL.md §4 `0x17 PINCH` istemci kuralları, §5 birleştirme ve karar 0009. Protokol değişikliği ve fixture'lar `proto/pinch` dalında (`c37b796`); T-036 (host) o daldan ilerliyor. Bu kartın dalı **T-035 merge edildikten sonra** güncel `main` + `proto/pinch` üstüne kurulur (orkestratör dalı hazırlar ya da ajan `main`'den açıp `proto/pinch`'i merge eder).

## Kabul kriterleri

- [ ] **Kodek:** `Pinch` mesajı, fixture testleri (`pinch_began`, `pinch`, `pinch_ended`) decode/encode bayt bayt; bilinmeyen `phase`/`source` protokol hatası.
- [ ] **Dokunmatik ekran** (`TouchTracker`): iki parmak hareketi ilk anlamlı harekette **kaydırma ya da yakınlaştırma** olarak sınıflanır ve hareket boyunca değişmez. Öneri: parmaklar arası uzaklığın göreli değişimi ≥ %6 iken ortak hareket kaydırma eşiğinin altındaysa PINCH; sabitler tek yerde, Handoff'ta. PINCH: BEGAN (merkez = iki parmağın ortası, normalize), CHANGED (`scale = d/d_önceki − 1`, `[-0,5, 1,0]`'a sıkıştır; merkez güncel), ENDED (bir parmak kalkınca). Parmak kuralı (§7, karar 0006): kalem menzildeyken ve son PEN'den sonra 1,2 sn yeni PINCH başlamaz; "parmak dokunmasını kapat" ayarı PINCH'i de kapatır.
- [ ] **Touchpad** (`RelPointerTracker`): aynı sınıflama iki parmakta; `source = TOUCHPAD`, merkez 0.
- [ ] Canlılık: açık hareket en geç 200 ms'de bir `CHANGED(0)`, 5 sn hareketsizlikte `ENDED` (mevcut kaydırma koduyla aynı düzen).
- [ ] **Tek hareket sahipliği:** T-034'teki `gate()` genişler: aynı anda tek bir açık SCROLL **ya da** PINCH, tek kaynaktan.
- [ ] **Bırakma:** release-all, odak/capture kaybı, cihaz sökülmesi açık PINCH'i `ENDED` ile kapatır (SCROLL ile aynı yol).
- [ ] **Outbox:** ardışık PINCH CHANGED birleştirilir (`(1+a)(1+b) − 1`, merkez sonuncunun); BEGAN/ENDED/CANCELLED hiçbir zaman birleştirilmez veya atılmaz.
- [ ] Sayaç: `pinch_msgs`. Birim testleri: sınıflama (kaydırma vs yakınlaştırma), ölçek hesabı ve sıkıştırma, parmak kalkınca ENDED, kalem kuralı, gate, birleştirme, bırakma yolları. `./scripts/check.sh` geçiyor.

## Kapsam dışı

- Host tarafı (T-036). Döndürme. Cihaz testi orkestratörde.

## Plan

1. **Kodek:** `Pinch` (0x17, 20 bayt gövde) + `Codec` encode/decode; phase 1..4 ve source 0..1 dışı protokol hatası; `FixtureTest`'e üç fixture.
2. **Sınıflama:** `TwoFingerClassifier` (saf, tek yerde sabitler): taban çizgisine göre parmak uzaklığı değişimi >= %6 ve ortak merkez hareketi < kaydırma eşiği ise PINCH; ortak hareket eşiği aşarsa SCROLL; aynı karede ikisi de aşarsa `|Δd| >= 2·ortak` ise PINCH. Karar ilk anlamlı harekette verilir, hareket boyunca değişmez. Ölçek = `d/d_önceki − 1`, `[-0.5, 1.0]` sıkıştırılır; karar anındaki birikmiş değişim BEGAN'ın ardından ilk CHANGED'de gider.
3. **TouchTracker:** ikinci parmakta BEGAN hemen gitmez; `UNDECIDED` modu (hiçbir şey gönderilmedi) karar verince SCROLL ya da PINCH açar. PINCH: BEGAN/CHANGED(merkez normalize)/ENDED (parmak kalkınca), keepalive 200 ms, 5 sn boşta ENDED + PARKED (aynı türde yeniden başlar), kalem aralığı / 1,2 sn kapısı (yeni BEGAN `blocked`), `disabled` ve kalem girişi açık PINCH'i CANCELLED ile kapatır (SCROLL ile aynı yol).
4. **RelPointerTracker:** aynı sınıflama iki parmakta, pad ölçüleriyle (eşik `extent·SLOP_FRAC`), `source = TOUCHPAD`, merkez 0; release / 2→1 parmak / tuş basışı / tüm parmaklar kalkınca ENDED; tick keepalive + idle end.
5. **InputCapture.gate:** tek açık phased hareket (SCROLL ya da PINCH), tek kaynaktan: sahip = (kaynak, tür).
6. **InputOutbox:** PINCH CHANGED birleştirme `(1+a)(1+b)−1` (aralık dışına çıkarsa birleştirme), sayaç `pinch_msgs`.
7. **Testler:** kodek, sınıflama (kaydırma vs yakınlaştırma), ölçek+sıkıştırma, parmak kalkınca ENDED, kalem kuralı, gate, birleştirme, bırakma yolları; mevcut iki parmak kaydırma testleri BEGAN ertelemesine göre güncellenir.

## Handoff

- **Commit:** dalın son commit'i (`git log -1 task/T-037-client-pinch`).
- **Dokunulan dosyalar:** `protocol/Messages.kt`, `protocol/Codec.kt` (Pinch); `input/TwoFingerClassifier.kt` (yeni, tüm eşikler), `TouchTracker.kt`, `RelPointerTracker.kt`, `InputCapture.kt` (gate), `InputOutbox.kt` (birleştirme, sayaç), `Model.kt` (`pinch_msgs`); testler: `PinchTest.kt` (yeni), `FixtureTest`, `CodecRulesTest`, `TestSupport` (`slide` yardımcısı), `TouchTrackerTest`, `InputHardeningTest`, `InputCaptureTest`, `RelPointerCaptureTest` (BEGAN ertelemesi için güncellendi).
- **Sınıflama eşikleri** (`TwoFingerClassifier`): PINCH_REL = %6 (baz çizgisine göre parmak uzaklığı değişimi); ortak hareket eşiği dokunmatikte 16 px (`SLOP_PX`), touchpad'de `extent * 0,02` (mevcut `SLOP_FRAC`); taban mesafe alt sınırı dokunmatikte 140 px, touchpad'de `extent * 0,05` (yakın parmak gürültüsü); aynı karede ikisi de aşılırsa `|Δd| >= 2·ortak` ise PINCH, değilse SCROLL. Karar bir kez verilir, hareket boyunca değişmez (5 sn boşta ENDED sonrası aynı türle yeniden başlar).
- **Davranış değişikliği (dokunmatik kaydırma):** ikinci parmakta SCROLL BEGAN artık hemen gitmez; ilk anlamlı harekette (BEGAN + birikmiş CHANGED) gider. Sınıflama için zorunlu. Hareketsiz iki parmak artık keepalive göndermez (açık hareket yok). Mevcut testler buna göre güncellendi.
- **Varsayımlar:** karar anında birikmiş ölçek BEGAN'ın ardından ilk CHANGED'de gider (kayıp yok). Bırakma yolları SCROLL ile aynı: dokunmatikte CANCELLED (kalem girişi, release-all, devre dışı, cihaz sökülmesi), touchpad'de ENDED (capture kaybı, release). Tek mesajda ölçek sıkıştırılırsa sonraki `d_önceki` güncel mesafe olur. Outbox birleştirmede çarpım `[-0,5, 1,0]` dışına çıkarsa birleştirilmez. Gate sahibi = (kaynak, tür). Touchpad'de `finishGesture` artık açık kaydırmayı/yakınlaştırmayı ENDED ile kapatır (iki parmak aynı karede kalkarsa açık kalmasın diye).
- **Test edilmeyenler / cihazda doğrulanacaklar:** iki parmak yakınlaştırmanın (ekran ve touchpad) eşik hissi (%6 / 16 px; gerekirse `TwoFingerClassifier`, `TouchTracker.SLOP_PX`); dokunmatikte kaydırmanın başlangıç gecikmesi (BEGAN ilk ~16 px harekete kadar bekliyor); kalemle çizerken parmak yakınlaştırmanın başlamaması; Mac tarafı T-036 ile uçtan uca (Krita tuval yakınlaştırma). HarmonyOS'un iki parmak hareketini kendi tüketip tüketmediği bilinmiyor.
- **Swift durumu:** `./scripts/check.sh` Gradle kısımları (client-android, input-probe) geçiyor; `swift test` yalnızca `FixtureTests.everyFixtureFileHasATestCase` ile düşüyor (yeni `pinch*` fixture'ları host'ta yok, T-036 bekleniyor). Başka hata yok.
- **Açık sorular:** yok.

## Orkestratör notu (merge, 2026-09-30)

- İnceleme: Codex (`gpt-6.1-sol`, medium): kod bulgusu yok; tek P1 "T-036 ile birlikte merge et" → aynı anda merge edildi, `check.sh` ALL OK.
- Not: dokunmatik ekranda iki parmak kaydırmanın BEGAN'ı artık ilk anlamlı harekete (≈16 px) kadar bekliyor (sınıflama için).
