---
id: T-009
title: Android iskeleti ve protokol kodeki — fixture testleriyle
status: todo
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

- [ ] Gradle projesi `client-android/`: tek `app` modülü, paket `dev.matebridge.client`, Kotlin, Views (Compose yok), `minSdk 29`, `targetSdk 31`. Araç zinciri sürümleri `probes/input-probe` ile aynı (Gradle wrapper, AGP, compileSdk). Yalnızca AndroidX core/appcompat, kotlinx-coroutines ve test için JUnit 4.
- [ ] En küçük `MainActivity`: yatay, tam ekran, "MateBridge — bağlantı yok" yazısı. Cihazda açılır (orkestratör doğrular).
- [ ] `dev.matebridge.client.protocol`: Android API'sine bağımlı olmayan saf Kotlin. PROTOCOL.md §4'teki **her** mesaj için veri sınıfı + encode (`ByteArray`) + decode. İşaretsiz alanlar Kotlin'de doğru aralıkta (ör. `u32` → `Long` ya da `UInt`, tutarlı seçim). Little-endian açıkça.
- [ ] Akış çözücü: parça parça gelen baytları biriktirir, tam çerçeveleri çıkarır. Bağlantı türüne göre en büyük payload sınırı (kontrol 64 KiB, video 16 MiB). Bilinmeyen tip atlanır. Kısa payload, sınır aşımı, `invalid_*` durumları, NaN/Inf `f32`, geçersiz `count`/`tool`/`action`, azalan `dt_us` → tipli protokol hatası.
- [ ] Fixture testleri (JVM):
  - `protocol/fixtures/*.hex` dosyalarını okuyup (yorumları ve boşlukları atarak) her geçerli fixture için elle yazılmış beklenen değerle decode karşılaştırması ve encode bayt eşitliği.
  - `invalid_*` fixture'ları hata verir, `unknown_type` atlanır ve ardından gelen geçerli çerçeve okunur.
  - Dizindeki **her** `.hex` dosyasının bir test vakası olduğunu doğrulayan test.
  - Akış çözücü, bir fixture'ı 1'er bayt ve rastgele parçalar halinde verince aynı sonucu üretir.
- [ ] Normalize koordinat, basınç ve eğim dönüşüm yardımcıları (§1, §4 PEN "Eğim yönü") birim testli.
- [ ] Tuş/karakter loglanmaz.
- [ ] `./scripts/check.sh` geçiyor.

## Notlar

- Fixture dizini testlerde proje köküne göre bulunur (ör. `../protocol/fixtures`, Gradle `testOptions`/sistem özelliğiyle). Kopyalanmaz.
- Değer anlamları ve fixture değerleri: `docs/PROTOCOL.md` ve her `.hex` dosyasındaki yorumlar. Çelişki görürsen kodla "düzeltme", Açık sorular'a yaz.
- Cihaza kurma ve test orkestratörde.

## Plan

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
