# 0015 — Tablet dosyaları Mac'te: tablette WebDAV sunucusu, yalnızca USB tüneli üzerinden

- **Durum:** kabul; madde 1'in yerini aldı: 0028 (2026-10-03)
- **Tarih:** 2026-10-02

## Bağlam
Kullanıcı Mac'ten tabletteki dosyalara erişmek istiyor ("çok işime yarar"): çizimleri, ekran görüntülerini, belgeleri Finder'da görmek, sürükleyip almak/göndermek. Koşulu: görüntü kalitesi ve akıcılık bozulmamalı. Kullanım genelde USB (Otomatik mod).

Seçenekler:
- **MTP:** macOS'ta yerleşik değil; ek uygulama (OpenMTP) gerekir, MateBridge ile bütünleşmez.
- **macFUSE / FSKit dosya sistemi:** sistem uzantısı ya da büyük iş; riskli.
- **Tablette WebDAV sunucusu + Finder'ın yerleşik WebDAV istemcisi:** Finder "Sunucuya Bağlan" ile ek yazılım olmadan bağlar; okuma/yazma, Range ile atlama desteklenir. Seçilen yol.

## Karar
1. **Tablet:** MateBridge uygulaması küçük bir WebDAV sunucusu çalıştırır (kendi kodumuz, **yeni bağımlılık yok**): `OPTIONS`, `PROPFIND` (Depth 0/1), `GET`/`HEAD` (Range), `PUT`, `DELETE`, `MKCOL`, `MOVE`, `COPY`, `LOCK`/`UNLOCK` (Finder'ın yazma için istediği sahte kilitler, class 2). Kök: paylaşılan depolama (`/sdcard`), "Tüm dosyalara erişim" izni (`MANAGE_EXTERNAL_STORAGE`) ile. İzin yoksa sunucu kapalı.
2. **Erişim yalnızca USB tünelinden:** sunucu yalnızca tabletin `127.0.0.1` adresine bağlanır; Mac `adb forward` ile yerel bir porta taşır. Wi-Fi ağına hiçbir şey açılmaz.
3. **Kimlik doğrulama:** tablet her sunucu başlangıcında rastgele bir jeton üretir (128 bit). Jeton Mac'e yalnızca şifreli kontrol kanalında `FILES_INFO` mesajıyla gider (PROTOCOL §4 0x09). Her istek HTTP kimlik doğrulaması (`matebridge` / jeton; Finder'ın düz HTTP'de Basic uyarısı çıkarması halinde Digest) ister; jetonsuz istek 401. Böylece tabletteki başka uygulamalar localhost üzerinden dosyalara erişemez. Jeton hiçbir yerde loglanmaz.
4. **Mac:** host, USB oturumunda `FILES_INFO READY` gelince `adb forward` kurar ve menü çubuğunda "Tablet dosyalarını aç" gösterir; seçilince WebDAV birimini bağlar (NetFS) ve Finder'da açar. Oturum/USB bitince forward kaldırılır, birim ayrılır. Wi-Fi oturumunda menü "yalnızca USB ile" der.
5. **Görüntüyü bozmama:** dosya aktarımı aynı USB/adb hattını video ile paylaşır. Sunucu aktarım hızını sınırlar (başlangıç tavanı ~20 MB/s; video 60 Mbps ≈ 7,5 MB/s, adb hattı ~30–40 MB/s) ve düşük öncelikli iş parçacıklarında çalışır. Boştayken maliyet sıfır. Tavan cihazda büyük kopya + hareketli görüntü ile ölçülüp ayarlanır.

## Sonuçlar
- PROTOCOL: yeni `FILES_INFO` (0x09, C→H), `HELLO.capabilities` bit10 `FILES`; fixture `files_info_ready`, `files_info_off`.
- Kartlar T-135 (tablet sunucu), T-136 (Mac forward + bağlama + menü).
- Tekrar düşünülür: Wi-Fi üzerinden erişim istenirse (TLS/şifreleme gerekir); tavan görüntüyü bozarsa (uyarlamalı tavan).
