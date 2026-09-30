---
id: T-037
title: Tablet — iki parmakla yakınlaştırma (dokunmatik ekran ve touchpad) → PINCH
status: todo
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

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
