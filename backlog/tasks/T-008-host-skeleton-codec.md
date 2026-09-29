---
id: T-008
title: Mac iskeleti ve protokol kodeki (MateBridgeCore) — fixture testleriyle
status: todo
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

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
