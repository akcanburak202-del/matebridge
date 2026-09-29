---
id: T-008
title: Mac iskeleti ve protokol kodeki (MateBridgeCore) — fixture testleriyle
status: review
phase: 1
owner: mac-host-dev
depends_on: [T-007]
decisions: [0002, 0005]
files:
  - host-mac/Package.swift
  - host-mac/Sources/MateBridgeCore/
  - host-mac/Sources/MateBridgeApp/
  - host-mac/Sources/MateBridgeHost/
  - host-mac/Tests/MateBridgeCoreTests/
---

## Amaç

`host-mac` Swift paketini kurmak ve `docs/PROTOCOL.md` v0'ın tamamını Swift'te encode/decode edebilmek. Bayt uyumu `protocol/fixtures/` ile kanıtlanır. Kotlin tarafı (T-009) aynı fixture'larla paralel yazılıyor.

## Kapsam dışı

- Ağ (soket, Bonjour), video, sanal ekran, girdi enjeksiyonu, girdi hakemliği (§7 durum makineleri). Bunlar sonraki kartlarda.
- `MateBridgeHost` hedefi yalnızca boş bir yer tutucu dosyayla oluşturulur (sonraki kartlar `Package.swift`'e dokunmadan paralel çalışabilsin diye).

## Kabul kriterleri

- [ ] `host-mac/Package.swift`: Swift 6 dil modu, macOS 15, hedefler `MateBridgeCore` (kütüphane), `MateBridgeHost` (kütüphane, Core'a bağımlı, şimdilik yer tutucu), `MateBridgeApp` (yürütülebilir, ikisine bağımlı), `MateBridgeCoreTests`. Üçüncü taraf bağımlılık yok.
- [ ] `MateBridgeApp`: en küçük menü çubuğu uygulaması (NSStatusItem, "MateBridge" menüsü ve "Quit"). `./scripts/bundle-host.sh` ile paketlenip imzalanabiliyor.
- [ ] `MateBridgeCore`: PROTOCOL.md §4'teki **her** mesaj için değer tipi + `encode() -> [UInt8]/Data` + decode. Enum alanları için tipli enum'lar; bilinmeyen enum değerlerinde PROTOCOL.md'nin söylediği davranış (hata ya da yok sayma).
- [ ] Akış çözücü (`FrameDecoder` veya benzeri): parça parça gelen baytları biriktirir, tam çerçeveleri çıkarır. Bağlantı türüne göre en büyük payload sınırı (kontrol 64 KiB, video 16 MiB). Bilinmeyen tip atlanır. Kısa payload, sınır aşımı, `invalid_*` durumları, NaN/Inf `f32`, geçersiz `count`/`tool`/`action`, azalan `dt_us` → tipli protokol hatası.
- [ ] Fixture testleri:
  - `protocol/fixtures/*.hex` dosyalarını okuyup (yorumları ve boşlukları atarak) her geçerli fixture için elle yazılmış beklenen değerle decode karşılaştırması ve encode bayt eşitliği.
  - `invalid_*` fixture'ları hata verir, `unknown_type` atlanır ve ardından gelen geçerli çerçeve okunur.
  - Dizindeki **her** `.hex` dosyasının bir test vakası olduğunu doğrulayan test (yeni fixture eklenince test kırılmalı).
  - Akış çözücü, bir fixture'ı 1'er bayt ve rastgele parçalar halinde verince aynı sonucu üretir.
- [ ] Normalize koordinat, basınç ve eğim dönüşüm yardımcıları (§1) birim testli.
- [ ] Log yok, tuş/karakter verisi yok.
- [ ] `./scripts/check.sh` geçiyor (host-mac `swift build` + `swift test`).

## Notlar

- Fixture yolu testlerde `#filePath`'ten yukarı çıkarak bulunur. Kopyalanmaz.
- Değer anlamları ve fixture değerleri: `docs/PROTOCOL.md` ve her `.hex` dosyasındaki yorumlar. Çelişki görürsen kodla "düzeltme", Açık sorular'a yaz.

## Plan

1. SwiftPM paketi (Swift 6, macOS 15): Core, Host (yer tutucu), App, CoreTests.
2. Core: `ByteIO` (LE okuyucu/yazıcı), `Messages` (değer tipleri + tipli enum'lar), `Message` (encode/decode), `FrameDecoder` (akış, başlıkta sınır denetimi, sınırlı tampon), `Geometry` (koordinat/basınç/eğim, sıfırdan uzağa yuvarlama).
3. Testler: fixture tablosu (decode, encode, 1 bayt / rastgele parça), her `.hex` için kapsama testi, ek kodek testleri.
4. App: NSStatusItem + Quit.

## Handoff

- **Commit:** c94e4cd (kod), kartın handoff güncellemesi ayrı commit
- **Dokunulan dosyalar:** `host-mac/Package.swift`, `host-mac/Sources/MateBridgeCore/{ByteIO,Geometry,FrameDecoder,Message,Messages,ProtocolConstants,ProtocolError}.swift`, `host-mac/Sources/MateBridgeHost/Placeholder.swift`, `host-mac/Sources/MateBridgeApp/main.swift`, `host-mac/Tests/MateBridgeCoreTests/{CodecTests,FixtureSupport,FixtureTests}.swift`, bu kart.
- **Varsayımlar:**
  - Yuvarlama sıfırdan uzağa (`.rounded()`), ±0.5 tie testleri var. `main` rebase edildi (§1 yuvarlama, §2 sınır, VIDEO_FRAME parça kuralları).
  - Bilinmeyen değer davranışı: `HELLO_ACK.status`, `STREAM_CONFIG.codec`, `PEN.tool`, `KEY.action`, `POINTER_ABS.source`, `SCROLL.phase` geçersizse protokol hatası (PROTOCOL.md yalnızca tool/action/count için hata diyor, diğerleri kart gereği tipli enum). BYE/RELEASE_ALL/KEYFRAME_REQUEST reason ve PEN_GESTURE.gesture bilinmeyen değerleri kabul edilir (`OpenCode` struct'ları), host yok sayar.
  - `Message.encode()` artık `throws`: kontrol 64 KiB / video 16 MiB sınırını (VIDEO_FRAME 24 baytlık başlığı dahil), PEN count 1-64 dışını ve TCP'de tek parçalı olmayan VIDEO_FRAME'i reddeder.
  - `FrameDecoder`: sınır 5 baytlık başlık gelir gelmez denetlenir; ilk hatadan sonra kalıcı `decoderFailed`. Tampon boşaltılmadan `header+max` üstüne çıkarsa decoder hata durumuna geçer. `append(ArraySlice)` slice indekslerine saygı duyar.
  - VIDEO_FRAME decode: `fragment_index != 0`, `fragment_count != 1`, `frame_size != veri uzunluğu` protokol hatası.
  - `PenFlags.normalized` (CONTACT && !IN_RANGE -> 0) yalnızca yardımcı, durum makinesi kapsam dışı.
- **Test edilmeyenler / cihazda doğrulanacaklar:** `swift test` 27 test geçiyor, `check.sh` ALL OK. Uygulama çalıştırıldı (2 sn açık kaldı, menü çubuğu öğesi görsel olarak doğrulanmadı). `./scripts/bundle-host.sh` denendi ama 5 dakikada bitmedi (muhtemelen imzalama/anahtar zinciri istemi), sonlandırıldı; paketleme + imzalama doğrulanmadı, orkestratör elle denemeli. Ağ, video, girdi enjeksiyonu yok.
- **Açık sorular:** yukarıdaki "geçersiz enum" seçimleri (status/codec/source/phase) PROTOCOL.md'de açıkça yazılı değil; onay veya belge açıklaması gerekir.
