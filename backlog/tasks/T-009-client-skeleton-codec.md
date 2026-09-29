---
id: T-009
title: Android iskeleti ve protokol kodeki — fixture testleriyle
status: done
phase: 1
owner: android-client-dev
depends_on: [T-007]
decisions: [0004, 0005]
files:
  - client-android/
---

## Amaç

`client-android` uygulamasını kurmak ve `docs/PROTOCOL.md` v0'ın tamamını Kotlin'de encode/decode edebilmek. Bayt uyumu `protocol/fixtures/` ile kanıtlanır. Swift tarafı (T-008) aynı fixture'larla paralel yazılıyor.

## Kapsam dışı

- Ağ (soket, NSD), video, girdi yakalama, girdi hakemliği. Bunlar sonraki kartlarda.

## Kabul kriterleri

- [x] Gradle projesi `client-android/`: tek `app` modülü, paket `dev.matebridge.client`, Kotlin, Views (Compose yok), `minSdk 29`, `targetSdk 31`. Araç zinciri sürümleri `probes/input-probe` ile aynı (Gradle wrapper, AGP, compileSdk). Yalnızca AndroidX core/appcompat, kotlinx-coroutines ve test için JUnit 4.
- [x] En küçük `MainActivity`: yatay, tam ekran, "MateBridge — bağlantı yok" yazısı. Cihazda açılır (orkestratör doğrular).
- [x] `dev.matebridge.client.protocol`: Android API'sine bağımlı olmayan saf Kotlin. PROTOCOL.md §4'teki **her** mesaj için veri sınıfı + encode (`ByteArray`) + decode. İşaretsiz alanlar Kotlin'de doğru aralıkta (ör. `u32` → `Long` ya da `UInt`, tutarlı seçim). Little-endian açıkça.
- [x] Akış çözücü: parça parça gelen baytları biriktirir, tam çerçeveleri çıkarır. Bağlantı türüne göre en büyük payload sınırı (kontrol 64 KiB, video 16 MiB). Bilinmeyen tip atlanır. Kısa payload, sınır aşımı, `invalid_*` durumları, NaN/Inf `f32`, geçersiz `count`/`tool`/`action`, azalan `dt_us` → tipli protokol hatası.
- [x] Fixture testleri (JVM):
  - `protocol/fixtures/*.hex` dosyalarını okuyup (yorumları ve boşlukları atarak) her geçerli fixture için elle yazılmış beklenen değerle decode karşılaştırması ve encode bayt eşitliği.
  - `invalid_*` fixture'ları hata verir, `unknown_type` atlanır ve ardından gelen geçerli çerçeve okunur.
  - Dizindeki **her** `.hex` dosyasının bir test vakası olduğunu doğrulayan test.
  - Akış çözücü, bir fixture'ı 1'er bayt ve rastgele parçalar halinde verince aynı sonucu üretir.
- [x] Normalize koordinat, basınç ve eğim dönüşüm yardımcıları (§1, §4 PEN "Eğim yönü") birim testli.
- [x] Tuş/karakter loglanmaz.
- [x] `./scripts/check.sh` geçiyor.

## Notlar

- Fixture dizini testlerde proje köküne göre bulunur (ör. `../protocol/fixtures`, Gradle `testOptions`/sistem özelliğiyle). Kopyalanmaz.
- Değer anlamları ve fixture değerleri: `docs/PROTOCOL.md` ve her `.hex` dosyasındaki yorumlar. Çelişki görürsen kodla "düzeltme", Açık sorular'a yaz.
- Cihaza kurma ve test orkestratörde.

## Plan

1. `probes/input-probe` araç zinciri (AGP 9.4.1, Gradle 9.8.0, compileSdk 37) kopyalanarak `client-android/` Gradle projesi; tek `app` modülü, yalnızca JUnit 4 test bağımlılığı.
2. `protocol` paketi: `Messages.kt` (veri sınıfları; u8/u16/i16 -> Int, u32 -> Long, u64 -> Long ham bit deseni), `Codec.kt` (LE okuyucu/yazıcı, encode/decode, doğrulamalar), `FrameDecoder.kt` (artımlı akış çözücü, başlıkta boyut sınırı, bilinmeyen tip atlama, kalıcı hata), `Coords.kt` (normalize, basınç, eğim).
3. Testler: fixture okuyucu (yorum/boşluk atar), elle yazılmış beklenen değerler, dizindeki her .hex için vaka kontrolü, 1 bayt ve rastgele parça besleme, ek kural testleri, Coords testleri.
4. `MainActivity`: tam ekran, yatay, ekran açık, sabit metin.

## Handoff

- **Commit:** bu branch'in tek commit'i (SHA orkestratör tarafından branch ucundan okunur)
- **Dokunulan dosyalar:** yalnızca `client-android/` (Gradle iskeleti, `app/`, `MainActivity`, `protocol/{Messages,Codec,FrameDecoder,Coords}.kt`, testler `FixtureTest`, `CodecRulesTest`, `CoordsTest`) ve bu kart.
- **Varsayımlar:**
  - Tip seçimi: u8/u16/i16 -> `Int`, u32 -> `Long`, u64 -> `Long` (ham bit deseni; zaman damgaları pozitif aralıkta).
  - Decode her bilinen tipi yöne bakmadan çözer (fixture testi iki yönü de gerektiriyor).
  - Enum kuralı (PROTOCOL.md §2): durumu belirleyen alanlarda bilinmeyen değer protokol hatası (`HELLO_ACK.status` 0..4, `STREAM_CONFIG.codec` 1..2, `PEN.tool` 0..1, `KEY.action` 0..1, `POINTER_ABS.source` 0..1, `SCROLL.phase` 0..4); decode ve encode aynı. Bilgi amaçlı alanlar (`BYE/RELEASE_ALL/KEYFRAME_REQUEST.reason`, `PEN_GESTURE.gesture`, renk kodları) ham Int olarak kabul edilir.
  - Ek doğrulamalar: `str8` > 64 bayt veya geçersiz UTF-8 -> hata; PEN `tilt` -32768 -> -32767 (§1).
  - VIDEO_FRAME: `fragment_index == 0`, `fragment_count == 1` şart; `data` tam `frame_size` bayt, payload'da `24 + frame_size`'dan az varsa `SHORT_PAYLOAD`, fazlası yok sayılır. Encoder `frame_size == data.size` ister.
  - Encoder payload'ı bağlantı sınırıyla denetler (kontrol 64 KiB, video 16 MiB; VIDEO_HELLO/VIDEO_FRAME video).
  - `FrameDecoder`: her 5 baytlık başlık `feed()` içinde tamamlanır tamamlanmaz denetlenir (payload tamponlanmadan `OVERSIZE`). `feed()` çağrı başına en çok `READ_CHUNK` (64 KiB) alır, fazlası `IllegalArgumentException` (çağıran hatası). Toplam tampon üst sınırı `bufferCap` = 5 + max payload + `READ_CHUNK`; yalnızca `next()` ile henüz döndürülmemiş baytlar sayılır. Çağıran her `feed()` sonrası `next()`/`drain()` ile boşaltmalıdır, aksi halde `BUFFER_OVERFLOW`. Hata sonrası kalıcı başarısız; çağıran bağlantıyı kapatır, hata sonrası gelen baytlar yok sayılır.
  - Yuvarlama: sıfırdan uzağa yarım yuvarlama (`Coords.roundHalfAway`).
  - Encode, geçersiz girdiyi `IllegalArgumentException` ile reddeder (pen sayısı, dt sırası, NaN vb.).
  - `targetSdk 31`, `compileSdk 37`, AGP 9.4.1, Gradle 9.8.0 probe ile aynı. `kotlinx-coroutines` henüz eklenmedi (gerek yok).
  - Fixture dizini Gradle test görevindeki `matebridge.fixtures` sistem özelliğiyle bulunur.
- **Test edilmeyenler / cihazda doğrulanacaklar:** `check.sh` geçti (JVM testleri dahil). Cihazda: APK kurulunca `MainActivity` yatay, tam ekran, siyah zeminde "MateBridge — bağlantı yok" göstermeli; ekran açık kalmalı. Ağ/video/girdi yok.
- **Açık sorular:** yok.

- **Açık sorular (T-013 için, inceleme düşük bulguları):** (1) `FrameDecoder` tamponu büyük kareden sonra küçülmüyor. (2) Codex bulgularının çoğu giderildi (frame_size denetimi, hata sonrası feed belgelendi).

## Orkestratör cihaz testi (2026-09-29)

APK MatePad'e kuruldu (ilk kurulumda Huawei güvenlik onayı gerekti). `MainActivity` yatay, tam ekran, siyah arka plan ve "MateBridge — bağlantı yok" yazısıyla açıldı. Durum çubuğu gizli.

