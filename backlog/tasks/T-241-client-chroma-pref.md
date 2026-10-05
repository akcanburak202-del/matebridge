---
id: T-241
title: Client — "Keskin renk kenarları" panel toggle and STREAM_PREFS.chroma (decision 0033)
status: review
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

**Durum: blocked.** Kodek değişikliği (`protocol/Messages.kt`, `protocol/Codec.kt`) yapılamadı. Ajanın düzenlemesini Claude Code izin sınıflandırıcısı reddetti ("Modify Shared Resources"). Dosyalar kartın `files:` listesinde olsa da ajan bu reddi aşmaya çalışmadı. Geri kalan her şey commit edildi.

- Commit: `86df92a` (uygulama), `8dfafb5` (plan). Dal `task/T-241-client-chroma` (`task/T-239-chroma-protocol` üstünde).
- Dokunulan dosyalar: `stream/SharpChroma.kt` (yeni: `SharpChromaStore`, `SharpChromaPolicy`), `stream/GameMode.kt` (`chromaStore`, `sharpChroma`, `chroma`, `selectSharpChroma`, `resetSharpChroma`), `settings/SettingsCatalog.kt` (`SettingsHost.sharpChroma`/`selectSharpChroma`, `sharp_chroma` satırı), `MainActivity.kt` (store, host, reset, `ev=profile … chroma=`), `docs/LOGGING.md`, testler `stream/SharpChromaTest.kt` (yeni) ve `settings/SettingsCatalogTest.kt`.
- `./scripts/check.sh --only android`: 1783 testten 1'i başarısız, beklenen: `FixtureTest` "fixtures without a test case" → `stream_prefs_sharp_chroma`. Yeni testlerin hepsi geçiyor. Tam `check.sh` çalıştırılmadı (host fixture testi zaten T-240'a kadar kırmızı).

**Kodeki tamamlamak için kalan iş (orkestratör ya da izinli bir ajan):**
1. `Messages.kt`: `StreamPrefs`'e `val chroma: Int = CHROMA_NORMAL`, `CHROMA_NORMAL = 0`, `CHROMA_SHARP = 1`. KDoc'u grup kuralına göre güncelle.
2. `Codec.kt` kodlama: `val drGroup = msg.dynamicRange != 0 || msg.chroma != 0`, ekran grubu koşulunda `hdrGroup` yerine `drGroup`, `if (drGroup) { w.u8(msg.dynamicRange); w.u8(msg.chroma) }`. Çözme: `val dr = r.u8(); val chroma = r.u8(); StreamPrefs(fps, pm, kbps, dw, dh, dr, chroma)`.
3. `GameMode.kt` `prefs()`: `StreamPrefs(..., dynamicRange(mode), chroma)`. `SharpChromaPolicy.CHROMA_*` yerine `StreamPrefs.CHROMA_*` kullanılabilir.
4. `FixtureTest`: `"stream_prefs_sharp_chroma" to StreamPrefs(60, 1000, 0, 0, 0, 0, StreamPrefs.CHROMA_SHARP)`. `CodecRulesTest`: yalnız chroma=1 → 14 bayt (`00 00 00 00 00 01`). İkisi 0 iken 8/12 bayt değişmez. Grup içindeki chroma artık okunur (`odd` vakası `chroma = 3` bekler). `SharpChromaTest`'e `prefs(mode).chroma` doğrulaması.

**Varsayımlar:**
- `session/Settings.kt` ve `session/DevKnobs.kt` (`StreamProfile`) listede değil. Bu yüzden ayar, T-234'ün `IdleTimeoutStore` örneği gibi aynı prefs deposunda ayrı bir anahtarda tutuluyor (`sharp_chroma`, `SharpChromaStore`). "Varsayılanlara dön" STREAM_PREFS gönderilmeden önce onu da siler ve `keys=` sayısına ekler. `ev=profile` satırına `chroma=0|1` MainActivity'de satırın **sonuna** ekleniyor.
- `chroma` her modda kayıtlı değer olarak istenir. HDR10'da host yok sayar. Satır HDR10 *uygulanırken* (`STREAM_CONFIG.transfer == 16`) gri ve not taşır, dokunuş yok sayılır (HDR satırının gri kuralıyla aynı). Akış yokken ya da SDR'de etkindir.
- Satır Görüntü bölümünde HDR satırlarından hemen sonra, iki panelde de (bağlanma + akış içi) yer alır.

**Tablette kontrol edilecekler (kodek tamamlandıktan sonra):**
1. Ayarlar → Görüntü: "Keskin renk kenarları" Kapalı/Açık üç modda da görünüyor, varsayılan Kapalı.
2. Açık'a dokun: Mac'te `ev=stream_prefs` yeni değerle geliyor, `ev=chroma_config applied=sharp_nearest` (T-240 ile), tablette yeni `ev=profile … chroma=1`. Kırmızı ikon kenarları keskinleşiyor.
3. Uygulamayı kapatıp aç: ayar Açık kalıyor (kalıcı).
4. Oyun + HDR açık + HDR10 uygulanınca satır gri, "(HDR açıkken etkisiz)", dokunuş bir şey yapmıyor.
5. "Varsayılanlara dön" → satır Kapalı, `ev=profile … chroma=0`.

## Open questions

- **Engel:** `protocol/Messages.kt` ve `protocol/Codec.kt` düzenlemesi (kartın kapsamında) izin sınıflandırıcısı tarafından reddedildi. Kullanıcı ya da orkestratör izin verirse ya da değişikliği kendisi yaparsa (yukarıdaki 1–4) kart tamamlanır.
- Ayar `session/Settings.kt` yerine ayrı bir anahtarda. Orkestratör `Settings`'e taşınmasını isterse küçük bir takip işi olur (`USER_KEYS`'e `sharp_chroma` eklenir, `SharpChromaStore` kalkar).
- `ev=profile`'da `chroma=` satır sonunda, `hdr=`'nin yanında değil (`StreamProfile` `session/DevKnobs.kt`'de, listede değil).

**Orkestratör (2026-10-05):** kullanıcı codec düzenlemesini açıkça onayladı ("Codec düzenleme izni veriyorum"); orkestratör Handoff'taki dört adımı uyguladı (`StreamPrefs.chroma`, grup yazma kuralı, decode, `GameModeSettings.prefs`, `FixtureTest` + `CodecRulesTest`). `CodecRulesTest`'teki eski "reserved yok sayılır" beklentisi `chroma = 7` olarak güncellendi. `./scripts/check.sh --only android` ALL OK.
