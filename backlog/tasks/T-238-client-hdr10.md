---
id: T-238
title: Client — HDR10 per decision 0032 (STREAM_PREFS dynamic_range codec, capability check, Oyun-mode panel toggle, decoder setup, logs)
status: in_progress
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

_(Ajan bitirince doldurur.)_
