---
id: T-264
title: Client — "Renk" varsayılanı Keskin kenarlar (0034 eki)
status: review
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

1. `ColourStore.get()`: kayıtlı `colour` geçerliyse o; yoksa eski `sharp_chroma`: yok -> SHARP (varsayılan), `"1"` -> SHARP, başka değer -> NORMAL. Tek yardımcı `legacyChoice` get ve migrate'te ortak.
2. `migrate()`: `colour` yoksa `legacyChoice(legacy)` değerini `colour`'a yazar (Kapalı -> normal, Açık -> sharp), eski anahtar silinir.
3. `reset()` anahtarları siler (varsayılan Keskin); `GameModeSettings.colourChoice()` depo yokken `ColourStore.DEFAULT` (SHARP). KDoc güncellenir.
4. JVM testleri: ColourPanelTest ve FullChromaPrefsTest güncellenir/eklenir.

## Handoff

- Commit: bkz. `git log task/T-264-default-sharp-colour` (tek commit, "T-264: ...").
- Dosyalar: `stream/ColourChoice.kt` (ColourStore: varsayılan SHARP, `legacyChoice`, `DEFAULT`; migrate Kapalı -> `normal` yazar; KDoc), `stream/GameMode.kt` (depo yokken `ColourStore.DEFAULT`, KDoc), testler: `ColourPanelTest`, `FullChromaPrefsTest` (yeni/güncel kabul testleri), `AutoBitrateLayerTest`, `GameModeTest`, `GameResolutionTest`, `HdrTest` (depo vermeyen testler artık `chroma=1` bekler; tel uzunluğu/golden kontrolleri `chroma=0` ile, çünkü golden `stream_prefs_game_display` ve 8/12 bayt grup uzunlukları `chroma` öncesi).
- Varsayımlar: eski `sharp_chroma` için "1 dışında kayıtlı her değer" Kapalı sayıldı (NORMAL). Bozuk `colour` değeri artık depo boşmuş gibi varsayılan SHARP verir (eskiden NORMAL). Protokol/host/fixture/panel metni değişmedi.
- Test edilmedi: cihazda hiçbir şey denenmedi; `./scripts/check.sh` ALL OK.
- Tablette kontrol: (1) uygulama verisi temizlenmiş/yeni kurulumda ilk bağlantıda panel "Renk" = Keskin kenarlar, log `ev=profile` `chroma=1`; (2) önceden Normal seçili cihazda Normal korunur; eski `sharp_chroma=0` kalmış cihazda Normal'e taşınır; (3) "Varsayılanlara dön" sonrası Renk = Keskin kenarlar, sonraki STREAM_PREFS `chroma=1`; (4) HDR10'da etkisiz kalmaya devam eder.

## Open questions
