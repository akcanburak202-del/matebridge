---
id: T-238
title: Client — HDR10 per decision 0032 (STREAM_PREFS dynamic_range codec, capability check, Oyun-mode panel toggle, decoder setup, logs)
status: done
phase: 6
owner: android-client-dev
depends_on: [T-231]
decisions: [0032]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/protocol/
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/
  - client-android/app/src/main/kotlin/dev/matebridge/client/settings/
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/
  - docs/LOGGING.md
  - backlog/tasks/T-238-client-hdr10.md
---

## Amaç

Decision 0032'nin istemci tarafı. Protokol ve fixture'lar orkestratörün `task/T-236-hdr-protocol` dalında. **Bu dalın üzerine kur** (`git checkout -b task/T-238-client-hdr10 task/T-236-hdr-protocol`). Protokolü değiştirme.

## Bağlam

- Codec: `STREAM_PREFS` 8/12/≥14 bayt; grup yazma kuralı (PROTOCOL.md §0x05: ekran grubu `0×0` olabilir, dinamik aralık grubu yalnız `≠0`). Fixture testleri üç yeni dosyayı kapsar.
- Yetenek: `Display.getHdrCapabilities()` HDR10 (tip 2) içeriyor **ve** HEVC çözücü `HEVCProfileMain10HDR10` bildiriyor (tablet: ikisi de evet, `hdr-probe` 2026-10-05). Bir kez hesapla, `ev=hdr_caps display_hdr10= decoder_main10hdr10=` logla.
- Panel: Oyun modunda "HDR" satırı (Kapalı/Açık, varsayılan Kapalı, kalıcı); yetenek yoksa gri "Bu cihazda yok"; Günlük/Çizim'de görünmez ya da gri. Açık + Oyun modu + yetenek → `dynamic_range=1`; mod değişince ya da kapatınca `0`.
- Çözücü: `STREAM_CONFIG` `transfer=16` ise HDR10: `ColorMapping` zaten 9→BT2020, 16→ST2084 eşliyor; `KEY_COLOR_RANGE` limited. `KEY_HDR_STATIC_INFO` gerekmez (prob: çözücü SEI'den okuyor). T-231 renk düğmeleri ve `ev=decoder_output_format` HDR'de de çalışır. Main10 çıkışı için yüzey/dataspace ayarı gerekiyorsa (prob `HdrProbeActivity.kt` nasıl yapıyorsa) uygula.
- Uygulanan HDR yalnız `STREAM_CONFIG`'ten anlaşılır; panelde "Uygulanan: HDR10 / SDR" göstergesi (bit hızındaki "Uygulanan" deseni).
- Log: `ev=hdr_request dynamic_range=` ve `ev=profile`'a `hdr=0|1`.
- APK kurma, tablete dokunma. Cihaz kabulünü orkestratör yapar.

## Kabul kriterleri

- [ ] [JVM] Üç yeni fixture decode/encode ve hata; eski fixture'lar değişmez.
- [ ] [JVM] İstek mantığı: (yetenek × mod × ayar) → `dynamic_range`; mod değişiminde yeniden gönderim; yetenek yoksa panel gri ve istek 0.
- [ ] [JVM] `STREAM_CONFIG` HDR10 kodları → çözücü format anahtarları (BT2020/ST2084/limited); SDR yol bit-bit aynı.
- [ ] `./scripts/check.sh` geçer (host tarafı fixture testleri T-237'de; bu dalda host fixture testi yeni dosyalar için düşebilir — yalnız istemci kısmının geçtiğini Handoff'a yaz).

## Plan

1. **Codec** (`protocol/`): `StreamPrefs.dynamicRange: Int = 0` (+ `DYNAMIC_RANGE_SDR/HDR10`). Encode: ekran grubu `display ≠ 0×0` **ya da** `dynamicRange ≠ 0` ise; dinamik aralık grubu (`u8 + reserved 0`) yalnız `≠ 0` ise. Decode: 8 → 0/0/0, 12 → ekran, ≥14 → ekran + `dynamic_range` (ham değer korunur; host bilinmeyeni 0 sayar), 9–11 ve 13 → SHORT_PAYLOAD. `StreamConfig.isHdr10` (`transfer == 16`). FixtureTest'e üç yeni fixture; eski fixture'lar değişmez.
2. **Saf mantık** (`stream/Hdr.kt`): `HdrCapability(displayHdr10, decoderMain10Hdr10)` + `fromHdrTypes()` / `firstHevcDecoder()` (createDecoderByType'ın seçeceği ilk HEVC çözücü) + `ev=hdr_caps` alanları; `HdrPolicy.dynamicRange(cap, mode, userOn)`; panel durumu (`rowHidden` Oyun dışı, `rowEnabled` yetenek, işaret " (Bu cihazda yok)"), `appliedLabel(config)` "Uygulanan: HDR10 / SDR / —"; `HdrRequestLog` (değişince bir `ev=hdr_request` satırı).
3. **Ayar** (`session/Settings.kt`): `hdrGame()` / `setHdrGame()`, anahtar `hdr_game`, varsayılan kapalı, `USER_KEYS`'e eklenir (Varsayılanlara dön kapatır).
4. **GameModeSettings**: yapıcıya `HdrCapability`; `dynamicRange(mode)`; `prefs(mode)` artık `dynamicRange` taşır (tüm gönderim yolları — mod değişimi, bit hızı, kare hızı, reset — kendiliğinden doğru değeri yollar); `selectHdr(on, mode)` saklar, Oyun + yetenekte tam STREAM_PREFS döner.
5. **Panel** (`settings/`): `SettingItem.Choice`'a `enabled` (gri, dokunulmaz), `SettingItem.Info`'ya `hidden`; Görüntü bölümüne "HDR" (Kapalı/Açık; Oyun dışında gizli; yetenek yoksa gri "(Bu cihazda yok)") ve yan panelde "Uygulanan: HDR10 / SDR" (Oyun dışında gizli). `SettingsHost`'a `hdrAvailable`, `hdrEnabled`, `setHdrEnabled`, `appliedHdr`.
6. **Çözücü** (`video/`): `ColorMapping` zaten 9→BT2020, 16→ST2084, `full_range=0`→limited; SDR yolu değişmez (test). Yalnız `ev=color_unsupported` uyarısı HDR10'da (`primaries=9` + `matrix=9`, BT2020 standardı primaries'i taşır) yazılmaz. Prob (`HdrProbeActivity`) yüzey/dataspace ayarı yapmadı (düz `SurfaceView` + `configure(surface)`), `KEY_HDR_STATIC_INFO` gerekmedi; istemci de yapmaz. `KEY_PROFILE` konmaz (çözücü SPS'ten okur).
7. **MainActivity**: onCreate'te yeteneği bir kez hesapla (`Display.hdrCapabilities` tip 2 + `MediaCodecList`), `ev=hdr_caps` logla, `GameModeSettings`'e ver; STREAM_PREFS gönderimini tek yardımcıdan geçir (`ev=hdr_request dynamic_range= mode= setting= capable=` değişimde); `ev=profile`'a `hdr=0|1` (uygulanan, STREAM_CONFIG'ten); `installConfig` panel tazelemesi "Uygulanan" satırını günceller.
8. **LOGGING.md**: `hdr_caps`, `hdr_request`, `profile hdr=`.
9. Testler: codec kuralları + fixture; `HdrPolicy` (yetenek × mod × ayar), mod değişiminde prefs; panel gizli/gri; ColorOverrides HDR10 anahtarları ve SDR değişmezliği; Settings reset; StreamProfile `hdr=`.

## Handoff

- **Commit:** `34a11b6` (uygulama), plan `4d8c0d7`; dal `task/T-238-client-hdr10` (`task/T-236-hdr-protocol` üzerinde). Push/merge yok.
- **Dosyalar:** `protocol/Messages.kt`, `protocol/Codec.kt`, `stream/Hdr.kt` (yeni), `stream/GameMode.kt`, `session/Settings.kt`, `session/DevKnobs.kt` (`StreamProfile.hdr`), `settings/SettingsCatalog.kt`, `settings/SettingsViews.kt`, `video/ColorMapping.kt`, `video/VideoRenderer.kt`, `MainActivity.kt`, `docs/LOGGING.md`; testler: `protocol/FixtureTest.kt`, `protocol/CodecRulesTest.kt`, `stream/HdrTest.kt` (yeni), `video/Hdr10DecoderFormatTest.kt` (yeni), `settings/SettingsCatalogTest.kt`, `settings/SettingsResetTest.kt`, `session/DevKnobsTest.kt`.
- **check.sh:** istemci kısmı geçiyor (`gradle (client-android)` OK, 1776+ JVM testi; fixture güncelliği OK). Genel sonuç **FAILURES** yalnız `swift test (host-mac)` `FixtureTests.everyFixtureFileHasATestCase` yüzünden: host üç yeni fixture'ı henüz kapsamıyor (T-237'nin işi, kartta öngörülmüş). Başka host hatası yok.
- **Ne yapıldı:**
  - Codec: `StreamPrefs.dynamicRange` (8/12/≥14 bayt; 9–11, 13 kısa). Yazma kuralı: ekran grubu `display ≠ 0×0` ya da dinamik aralık yazılacaksa (`0×0` olabilir); dinamik aralık yalnız `≠ 0`. Decode bilinmeyen değeri ham tutar. `StreamConfig.isHdr10` = `transfer == 16`. Eski fixture'lar ve SDR baytları değişmedi.
  - İstek: `GameModeSettings.prefs(mode)` artık `dynamic_range` taşır → mod değişimi, bit hızı, kare hızı, oyun çözünürlüğü ve "Varsayılanlara dön" gönderimleri kendiliğinden doğru değeri yollar. `1` yalnız Oyun + "HDR: Açık" + yetenek.
  - Yetenek: `onCreate`'te bir kez: `Display.getHdrCapabilities()` tip 2 **ve** kod çözücü listesindeki ilk HEVC çözücü (`createDecoderByType`'ın seçeceği) `HEVCProfileMain10HDR10`. `ev=hdr_caps`.
  - Panel: Görüntü bölümünde "HDR" (Kapalı/Açık, varsayılan Kapalı, kalıcı `hdr_game`, reset kapatır); Günlük/Çizim'de **gizli**; yetenek yoksa gri, "HDR (Bu cihazda yok)", dokunma etkisiz. Yan panelde "Uygulanan: HDR10 / SDR / —" (yalnız STREAM_CONFIG'ten; Oyun dışında gizli). `SettingItem.Choice.enabled` ve `SettingItem.Info.hidden` eklendi.
  - Çözücü: `ColorMapping` zaten 9→BT2020(6), 16→ST2084(6), `full_range=0`→limited(2); HDR10 için başka anahtar yok (`KEY_HDR_STATIC_INFO`, `KEY_PROFILE` konmaz). SDR format bit-bit aynı (test). HDR10'da sahte `ev=color_unsupported primaries=9` uyarısı artık yazılmıyor (BT.2020 birincilleri standart anahtarıyla taşınıyor). T-231 renk düğmeleri HDR'de de çalışır.
  - Loglar: `ev=hdr_caps`, `ev=hdr_request dynamic_range= mode= setting= capable=` (yalnız değişimde + açılışta bir kez), `ev=profile … hdr=0|1` (uygulanan).
- **Varsayımlar:**
  - Yüzey/dataspace ayarı gerekmez: `hdr-probe` düz `SurfaceView` + `configure(surface)` ile HDR10 gösterdi (SF katmanı `BT2020_ITU_PQ`). İstemci de bir şey eklemedi.
  - Paneldeki "HDR" satırı Oyun dışında gizli (kart "görünmez ya da gri" dedi; "Kare hızı"nın Çizim'deki deseni seçildi). Yetenek yokken kayıtlı ayar değiştirilmez.
  - `ev=profile hdr=` uygulananı gösterir (istek `ev=hdr_request`'te).
- **Test edilmedi (tablet gerekir):** gerçek yetenek tespiti, Main10 çözme ve HDR görüntü, mod geçişlerinde ekran yeniden kurulumu, panel görünümü (gri satır), 10-bit çözme süresi / 120 fps payı. Host tarafı (T-237) olmadan uçtan uca HDR olmaz: eski host 14 baytlık payload'un fazlasını yok sayar, `Uygulanan: SDR` görünür.
- **Tablette kontrol (orkestratör, T-237 ile birlikte):**
  1. Açılışta `adb logcat -s 'MB:*' | grep hdr_caps` → `display_hdr10=1 decoder_main10hdr10=1`.
  2. Günlük/Çizim'de panelde "HDR" satırı yok; Oyun'a geçince "HDR: Kapalı" görünür, `ev=hdr_request dynamic_range=0 mode=game …` (ilk satır açılışta).
  3. Oyun'da "Açık"a dokun → `ev=hdr_request dynamic_range=1 mode=game setting=on capable=1`, yeni STREAM_CONFIG sonrası `ev=profile … hdr=1`, `ev=decoder_output_format … req_standard=6 req_transfer=6 req_range=2` (çıkış `standard=6 transfer=6` beklenir), yan panelde "Uygulanan: HDR10"; `ev=color_unsupported` yok. `dumpsys SurfaceFlinger` katman dataspace `BT2020_ITU_PQ`.
  4. Oyun'dan Günlük'e geç → `dynamic_range=0`, `ev=profile hdr=0`, görüntü normal SDR (siyah/beyaz seviyeleri T-231 öncesiyle aynı).
  5. Uygulamayı kapat-aç: Oyun'da HDR ayarı kalıcı; "Varsayılanlara dön" sonrası Kapalı.

### Open questions

- Yok (host fixture testi T-237'de kapanacak).
