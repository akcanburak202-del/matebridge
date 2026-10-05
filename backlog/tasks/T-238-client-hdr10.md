---
id: T-238
title: Client — HDR10 per decision 0032 (STREAM_PREFS dynamic_range codec, capability check, Oyun-mode panel toggle, decoder setup, logs)
status: todo
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

_(Ajan kodlamadan önce doldurur.)_

## Handoff

_(Ajan bitirince doldurur.)_
