---
id: T-241
title: Client — "Keskin renk kenarları" panel toggle and STREAM_PREFS.chroma (decision 0033)
status: in_progress
phase: 6
owner: android-client-dev
depends_on: [T-238]
decisions: [0033]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/protocol/
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/
  - client-android/app/src/main/kotlin/dev/matebridge/client/settings/
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/
  - docs/LOGGING.md
  - backlog/tasks/T-241-client-chroma-pref.md
---

## Amaç

Decision 0033'ün istemci tarafı. Protokol ve fixture'lar `task/T-239-chroma-protocol` dalında; **bu dalın üzerine kur** (`git checkout -b task/T-241-client-chroma task/T-239-chroma-protocol`). Protokolü değiştirme.

## Bağlam

- Codec: grup `reserved` → `chroma`; yazma kuralı `dynamic_range ≠ 0 || chroma ≠ 0`; fixture'lar (`stream_prefs_sharp_chroma` yeni, `stream_prefs_hdr` alan adı).
- Panel: Görüntü bölümünde "Keskin renk kenarları" (Kapalı/Açık), varsayılan Kapalı, kalıcı (prefs), bütün modlarda; HDR10 uygulanırken (`STREAM_CONFIG.transfer == 16`) gri ve "(HDR açıkken etkisiz)" notu. "Varsayılanlara dön" kapatır. Değişince `STREAM_PREFS` yeniden gönderilir (T-238'in `GameModeSettings.prefs(mode)` yolu).
- Log: `ev=profile`'a `chroma=0|1`.

## Kabul kriterleri

- [ ] [JVM] Fixture'lar; prefs → `chroma` alanı ve grup yazma kuralı (yalnız chroma=1 iken 14 bayt, ikisi 0 iken 8/12 bayt aynı).
- [ ] [JVM] Panel satırı (görünürlük, HDR'de gri, reset).
- [ ] `./scripts/check.sh` istemci kısmı geçer (host fixture testi T-240'ta).

## Plan

1. **Codec** (`protocol/`): `StreamPrefs.chroma: Int = CHROMA_NORMAL` (`CHROMA_NORMAL=0`, `CHROMA_SHARP=1`); grup `dynamicRange != 0 || chroma != 0` ise yazılır (`u8 dynamic_range, u8 chroma`); çözümde `chroma` okunur (bilinmeyen değer olduğu gibi). FixtureTest'e `stream_prefs_sharp_chroma`, `stream_prefs_hdr` chroma=0; CodecRulesTest'e yazma kuralı (yalnız chroma=1 → 14 bayt, ikisi 0 → 8/12 bayt değişmez).
2. **Kalıcı ayar** (`stream/SharpChroma.kt`): `Settings.kt` (`session/`) kartın `files:` listesinde değil; bu yüzden T-234'teki `IdleTimeoutStore` örneği gibi aynı `KeyValueStore` üzerinde ayrı küçük `SharpChromaStore` (anahtar `sharp_chroma`, varsayılan kapalı, `reset()`). `SharpChromaPolicy`: başlık, "(HDR açıkken etkisiz)" notu, HDR10 uygulanırken (`StreamConfig.isHdr10`) satır gri, seçili seçenek, `chroma` değeri, `ev=profile` alanı.
3. **GameModeSettings** (`stream/`): isteğe bağlı `chromaStore`; `prefs(mode)` bütün modlarda `chroma`'yı taşır; `selectSharpChroma(on, mode)` değişince tam `STREAM_PREFS` döndürür.
4. **Panel** (`settings/`): `SettingsHost.sharpChroma` + `selectSharpChroma`; Görüntü bölümünde HDR satırından sonra `sharp_chroma` Choice (Kapalı/Açık), hep görünür, HDR10 uygulanırken gri + not.
5. **MainActivity**: store'u kur, host'u bağla, "Varsayılanlara dön"de `prefs` gönderilmeden önce sıfırla (`keys=` sayısına eklenir), `ev=profile` satırının sonuna `chroma=0|1` (StreamProfile `session/`'da, listede değil → MainActivity'de `SharpChromaPolicy.profileField` eklenir).
6. **LOGGING.md**: istemci `ev=profile` satırına `chroma=0|1`.
7. JVM testleri: SharpChromaTest (store, policy, GameModeSettings prefs/select/reset), SettingsCatalogTest (görünürlük, HDR'de gri, seçim), SettingsResetTest gerekirse.

## Handoff

_(Ajan bitirince doldurur.)_
