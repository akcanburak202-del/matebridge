---
id: T-264
title: Client — "Renk" varsayılanı Keskin kenarlar (0034 eki)
status: todo
phase: 6
owner: android-client-dev
depends_on: [T-260]
decisions: [0034, 0033]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/
  - client-android/app/src/main/kotlin/dev/matebridge/client/settings/
  - client-android/app/src/test/kotlin/dev/matebridge/client/
  - backlog/tasks/T-264-default-sharp-colour.md
---

## Amaç

Karar 0034 eki (2026-10-06): panelin "Renk" satırında varsayılan **Keskin kenarlar** olur (bugün Normal). Tek ayar, bütün modlar.

## Kabul

- Hiç değer kaydı olmayan kurulumda `ColourStore.get()` = `SHARP`; ilk bağlantıda `STREAM_PREFS.chroma = 1` gider (HDR10'da host bugünkü gibi yok sayar).
- Kullanıcının açık seçimi korunur: kayıtlı `colour` (normal/sharp/full) aynen geçerli.
- Eski 0033 anahtarı (`sharp_chroma`): `"1"` → `SHARP` (bugünkü gibi); **açıkça kapalı değer** (`"1"` dışında kayıtlı bir değer) → `NORMAL` olarak `colour`'a taşınır (yoksa yeni varsayılan, kullanıcının "Kapalı" seçimini ezerdi). `get()` taşıma öncesinde de aynı sonucu verir.
- "Varsayılanlara dön" Keskin kenarlara döner (`reset()` anahtarı siler, varsayılan Keskin).
- `GameMode.colourChoice()` gibi depo yokken kullanılan geri dönüşler de Keskin.
- KDoc/yorumlardaki "Default [NORMAL]" ifadeleri güncellenir; panel metni değişmez.
- JVM testleri: boş depo → SHARP; `colour=normal` → NORMAL; legacy `"1"` → SHARP; legacy `"0"` → NORMAL (get ve migrate); reset → SHARP; `chromaRequest` varsayılan seçimle `CHROMA_SHARP`.
- Protokol, host ve fixture değişmez.

## Plan

(ajan doldurur)

## Handoff

## Open questions
