---
id: T-280
title: Client — HDR anahtarı Günlük modunda da (mod başına ayrı ayar)
status: done
phase: 6
owner: android-client-dev
depends_on: []
decisions: [0032, 0033, 0034]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/
  - client-android/app/src/test/kotlin/dev/matebridge/client/
  - backlog/tasks/T-280-hdr-daily-mode.md
---

## Amaç

Karar 0032 güncellemesi (2026-10-06): film ve video izlemek için HDR anahtarı **Günlük** modunda da olsun. Bugün yalnız Oyun'da var (`HdrPolicy.dynamicRange`/`rowHidden` → `mode.isGame`). Host ve protokol değişmez: host `dynamic_range`'i moddan bağımsız uygular.

## Kabul

1. **Mod başına ayrı, kalıcı ayar:** Oyun'un mevcut ayarı (`hdrGame`) aynen kalır, kayıtlı değer taşınır. Günlük için ayrı yeni ayar eklenir, varsayılan **Kapalı**. Oyun'da açık HDR, Günlük'e geçince uygulanmaz; tersi de geçerli. Çizim'de satır gizli, istek SDR.
2. `HdrPolicy.dynamicRange` HDR10'u şu koşulların hepsi tutunca ister: yetenek var + mod Günlük ya da Oyun + **o modun** ayarı açık. `rowHidden` yalnız Çizim'de true. Panel satırı ve "Uygulanan: HDR10/SDR" bilgisi Günlük'te de görünür. Yetenek yoksa bugünkü gibi gri "(Bu cihazda yok)".
3. Satır, değeri o anki modun ayarından okur ve değişikliği o moda yazar. Akış sırasında değişim bugünkü yolla `STREAM_PREFS` gönderir. Mod değişince istek yeni modun ayarına göre yeniden hesaplanır.
4. Günlük + HDR10 uygulanınca renk satırı bugünkü gibi gri "(HDR açıkken etkisiz)" olur (0033/0034). Tam renk tercihi silinmez; HDR kapanınca geri gelir.
5. `ev=hdr_request` alanları değişmez (`mode=` zaten var). "Varsayılanlara dön" iki HDR ayarını da Kapalı yapar. Mevcut "HDR yalnız Oyun" yorumlarını ve KDoc'u güncelle.
6. JVM testleri: Günlük açık → HDR10, Günlük kapalı/Oyun açık → Günlük'te SDR, Çizim hep SDR, yeteneksiz hep SDR, satır görünürlüğü, mod başına okuma/yazma, varsayılanlara dönüş, eski kayıtlı Oyun değerinin korunması.
7. `./scripts/check.sh`. Tablete dokunma, Mac'te pencere açma.

## Plan

1. `Settings`: yeni `KEY_HDR_DAILY = "hdr_daily"`, `hdrDaily()`/`setHdrDaily()`; `hdrFor(mode)`/`setHdrFor(mode, on)` (Oyun -> eski `hdr_game`, Günlük -> `hdr_daily`, Çizim -> false/yoksay). `hdr_game` anahtarı ve değeri aynen kalır; `USER_KEYS`'e `hdr_daily` eklenir (Varsayılanlara dön ikisini de siler).
2. `HdrPolicy`: `dynamicRange(cap, mode, userOn)` -> `cap.supported && (Günlük || Oyun) && userOn` (`userOn` = o modun ayarı); `rowHidden` yalnız Çizim; KDoc ve yorumlar güncellenir.
3. `GameModeSettings`: `hdrSetting` -> `hdrSetting(mode)`; `dynamicRange(mode)` o modun ayarını okur; `selectHdr(on, mode)` o moda yazar (Çizim: yazmaz, null), istek değişirse `prefs(mode)` döner. Mod değişince `prefs(mode)` zaten yeni modun ayarını okur.
4. `SettingsCatalog`/`MainActivity`: `hdrEnabled` o anki modun ayarı; `ev=hdr_request` `setting=` o modun ayarı. Satır/Info gizleme `rowHidden` ile (Çizim). Yorum "yalnız Oyun" güncellenir.
5. Testler: `HdrTest` (karar tablosu, mod başına okuma/yazma, eski `hdr_game` korunur, mod değişimi, Tam renk + HDR10), `SettingsCatalogTest` (satır Günlük'te görünür, Çizim'de gizli), `SettingsResetTest` (iki ayar da Kapalı).
6. `./scripts/check.sh`.

## Handoff

- **Commit:** bkz. `git log task/T-280-hdr-daily-mode` (son commit "T-280: HDR switch in Günlük, per-mode setting").
- **Dosyalar:** `session/Settings.kt` (yeni `hdr_daily` anahtarı, `hdrDaily/setHdrDaily`, `hdrFor/setHdrFor(mode)`, `USER_KEYS`'e eklendi), `stream/Hdr.kt` (`HdrPolicy.dynamicRange`: Çizim hariç + o modun ayarı; `rowHidden` yalnız Çizim), `stream/GameMode.kt` (`hdrSetting(mode)`, `dynamicRange(mode)`, `selectHdr(on, mode)` o moda yazar, Çizim'de null), `MainActivity.kt` (`hdrEnabled` o anki modun ayarı, `ev=hdr_request setting=` o modun ayarı), `settings/SettingsCatalog.kt` + `SettingsViews.kt` (yalnız yorum/KDoc), testler: `HdrTest`, `SettingsCatalogTest`, `SettingsResetTest`.
- **Varsayımlar:** `hdr_game` anahtarı ve değeri aynen; Günlük için `hdr_daily`, varsayılan Kapalı. Satır Günlük'te de görünür; yetenek yoksa gri "(Bu cihazda yok)". Renk satırı değişmedi: zaten `appliedConfig.isHdr10`'a bakıyor (Günlük HDR10'da gri), `FullChromaPolicy.eligible` zaten SDR şartı arıyor, Tam renk tercihi silinmez; HDR kapanınca `chroma=2` geri gelir (testle doğrulandı). Host/protokol değişmedi. `docs/LOGGING.md` 576. satır (`ev=hdr_request ... 1 yalnız Oyun + ayar açık`) kart `files:` dışında olduğu için güncellenmedi; orkestratör "Günlük ya da Oyun, o modun ayarı açık" diye düzeltmeli.
- **Test:** `./scripts/check.sh --only android` OK (HdrTest 17 test; `resetToDefaults` artık 21 anahtar sayar). Tam `./scripts/check.sh` sonucu teslim mesajında.
- **Tablette denenecek (test edilmedi):** (1) Günlük'te panelde "HDR: Kapalı/Açık" satırı ve (akışta) "Uygulanan: SDR/HDR10" görünsün; Açık -> ekran kısa kararıp yeniden kurulur, "Uygulanan: HDR10"; Renk satırı gri "(HDR açıkken etkisiz)". (2) Oyun'a geç: Oyun'un kendi HDR ayarı (önceden açıksa açık) geçerli, Günlük'ün ayarı onu etkilemesin; Oyun'da kapalıysa Günlük'e dönüşte Günlük'ün ayarı uygulanır. (3) Çizim'de satır ve "Uygulanan" gizli, akış SDR. (4) Günlük HDR kapat -> SDR'ye döner, Tam renk seçiliyse 60 fps'te geri gelir. (5) "Varsayılanlara dön": iki HDR de Kapalı. (6) logcat: `ev=hdr_request mode=daily setting=on dynamic_range=1`.

## Open questions
