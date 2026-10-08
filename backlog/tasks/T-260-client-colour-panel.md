---
id: T-260
title: Client panel — "Renk: Normal / Keskin kenarlar / Tam renk" (decision 0034), migrate the 0033 setting
status: done
phase: 6
owner: android-client-dev
depends_on: [T-259]
decisions: [0034, 0033]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/settings/
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/
  - client-android/app/src/test/kotlin/dev/matebridge/client/
  - backlog/tasks/T-260-client-colour-panel.md
---

## Amaç

Karar 0034 §2: panelde "Keskin renk kenarları" (Kapalı/Açık) satırı **"Renk"** olur: **Normal / Keskin kenarlar / Tam renk**, varsayılan Normal, kalıcı. Kayıtlı 0033 değeri taşınır (Açık → Keskin kenarlar). T-259'un dalı üzerine kur.

## Bağlam

- "Tam renk" yalnız Günlük 60'ta uygulanır; diğer modlarda satır notu "Tam renk yalnız Günlük 60'ta, şimdi: Keskin kenarlar". `FullChromaCapability` (T-259) yoksa seçenek gri "Bu cihazda yok". HDR10 uygulanırken bugünkü gri not aynen.
- Uygulanan durum notu: host `chroma_layout = 1` bildirdiyse "Uygulanan: Tam renk", geri düştüyse "Uygulanan: Normal (Mac yetişemedi)".
- Sözcükler panelde Türkçe; kod İngilizce.

## Kabul kriterleri

- [x] Taşıma + seçenek mantığı birim testli; `./scripts/check.sh` geçer.

## Plan

1. `ColourStore` taşıma/sıfırlama (`sharp_chroma` Açık -> `colour=sharp`, eski anahtar silinir), `ColourPolicy` (etiketler, seçili, not/uygulanan satırları).
2. `GameModeSettings.selectColour/resetColour/fullChromaCapable`; eski `SharpChromaStore/Policy` kaldırılır.
3. `SettingsCatalog`: "colour" satırı + "colour_note" + "colour_applied"; `Option.enabledWhen` ile tek düğme grisi; `SettingsViews` bunu uygular.
4. MainActivity yalnız `SettingsHost` bağlama (kapsam dışı ama zorunlu, aşağıya bak).

## Handoff

**Commit:** `git log -1 task/T-260-colour-panel` (T-259 dalı üzerine).

**Dosyalar:** `settings/SettingsCatalog.kt`, `settings/SettingsViews.kt`, `stream/ColourChoice.kt` (ColourStore + ColourPolicy), `stream/GameMode.kt`, `stream/SharpChroma.kt` (silindi); testler: `ColourPanelTest` (yeni), `SettingsCatalogTest`, `FullChromaPrefsTest` (eski-anahtar testi çıkarıldı), `SharpChromaTest` (silindi). Kapsam dışı ama zorunlu: `MainActivity.kt` (SettingsHost uygulaması, reset, `ev=profile chroma=` artık `chromaFor(mode)`).

**check.sh:** `--only android` geçer.

**Davranış:** satır "Renk": Normal / Keskin kenarlar / Tam renk (varsayılan Normal). Yetenek yoksa gri "Tam renk (Bu cihazda yok)", seçili görünen Keskin kenarlar. HDR10 uygulanırken satır gri "(HDR açıkken etkisiz)". Not satırı ("Tam renk yalnız Günlük 60'ta, şimdi: Keskin kenarlar"): Tam renk seçili ve yetenekli ama istek `chroma=2` değilken. Uygulanan satırı (yalnız akışta, yalnız istek `chroma=2` iken): `chroma_layout=1` -> "Uygulanan: Tam renk", değilse "Uygulanan: Normal (Mac yetişemedi)". Açılışta eski `sharp_chroma=1` -> `colour=sharp`. Seçim hep saklanır; STREAM_PREFS yalnız istenen `chroma` değişirse gider (ör. Günlük 120'de Keskin<->Tam renk göndermez).

**Tablette kontrol:** (1) panelde "Renk" satırı üç düğme; (2) self-test geçtiyse Tam renk seçilebilir, Günlük 60'ta "Uygulanan: Tam renk"; (3) 120 fps'e geçince not satırı görünür; (4) Oyun+HDR açıkken satır gri; (5) eski sürümden güncellemede Açık olan Keskin ayarı "Keskin kenarlar" gelir; "Varsayılanlara dön" Normal yapar.

**TEST EDİLMEDİ:** cihaz/arayüz görünümü (gri düğme, satır yenileme STREAM_CONFIG gelince).

## Open questions

- `MainActivity.kt` kart `files:` listesinde yok; `SettingsHost` orada uygulandığından küçük bağlama değişikliği gerekti.
