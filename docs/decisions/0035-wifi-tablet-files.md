# 0035 — Tablet dosyaları Wi-Fi'da: şifreli ayrı dosya bağlantısı, yalnız MateBridge klasörü, 256 MB sınırı

- **Durum:** kabul (kullanıcı 2026-10-06); uygulama 0034 cihaz kabulünden sonra
- **Tarih:** 2026-10-06

## Bağlam

0015/0028: tablet dosyaları yalnız USB'de (tablette 127.0.0.1 WebDAV, `adb forward`). Kullanıcı küçük dosyalara Wi-Fi'da da (Mac Ethernet, tablet Wi-Fi) Finder'dan erişmek istiyor. Tasarım: `docs/research/2026-10-05-wifi-files.md`. WebDAV istemcileri (macOS webdavfs, Windows WebClient, Linux davfs2) dosyayı açınca/önizleyince tamamını indiriyor; Wi-Fi'da dosya payı ~2 MB/s (görüntü korunur).

## Karar

1. **Yol:** araştırmanın A seçeneği. Tablet Mac'e ayrı, şifreli dosya bağlantıları açar (tablette LAN'a yeni port yok), anahtarlar oturum `prk` + iki taze nonce'tan; Mac'te 127.0.0.1 yerel uç, Finder/NetFS onu bağlar; tablet kendi 127.0.0.1 WebDAV sunucusuna iletir. Kontrol bağlantısına dokunulmaz.
2. **Ayrı ayar yok:** Wi-Fi dosya bağlantısı yalnız kullanıcı Mac menüsünden "Tablet dosyalarını aç" dediğinde kurulur (USB'deki gibi; tıklama onaydır). Kablo varsa USB yolu, yoksa Wi-Fi yolu.
3. **Wi-Fi'da kök yalnız `/sdcard/MateBridge/`** (kullanıcının paylaşım klasörü). USB'de bugünkü kök değişmez.
4. **Boyut sınırı yalnız Wi-Fi'da:** 256 MB üstü dosyaların tablettan okunması (açma/kopyalama) Wi-Fi'da reddedilir (Finder'a anlaşılır hata); Mac'ten tablete yazma ve listeleme her boyutta serbest. **USB etkilenmez.**
5. **Hız:** araştırmadaki kural (görüntü hedefine göre ~0,5–3 MB/s tavan, akış yokken daha yüksek, küçük istekler için ayrı şerit, arka plan önceliği).
6. Protokol (yeni mesajlar, `HELLO` bit12 `FILES_NET`, fixture'lar) orkestratör yazar; Codex `--high`.

## Sonuçlar

- Wi-Fi'da MateBridge klasöründeki dosyalar Finder'da; büyük medya klasörleri görünmez, Finder'ın kendiliğinden büyük indirme riski düşer.
- ~7–8,5 ajan günü (araştırma §5); protokol/host/istemci kartları 0034 birleştikten sonra.
- **Tekrar düşünülür:** SMB probu (aşağıda) olumluysa Wi-Fi (ve belki USB) yolu SMB'ye geçebilir; o zaman boyut sınırı kalkar.

## Ertelenen: SMB araştırma probu

macOS'un SMB istemcisi kısmi okuma yapar (önizleme bütün dosyayı indirmez). Tablette uygulama içi SMB sunucusu (aday: JFileServer, LGPL, Java) + Mac yerel uç (`smb://127.0.0.1:<port>`) ile denenebilir. Kullanıcı 2026-10-06: başka bir güne ertelendi, kayıt altında. Prob soruları: Android'de çalışıyor mu, Finder bağlanıyor mu, önizlemede yalnız kısmi okuma mı, lisans/boyut/bağımlılık karar kaydı.

## Ek (2026-10-06, kullanıcı): kök `MateBridge/Wi-Fi`, boyut sınırı yok

- §3 yerine: **Wi-Fi'da kök `/sdcard/MateBridge/Wi-Fi/`** (yoksa tablet oluşturur). Kullanıcı MateBridge içinde iki klasör tutar; Wi-Fi'da yalnız bu alt klasör görünür, diğeri hiç listelenmez. USB'de kök değişmez (ikisi de görünür).
- §4 kaldırıldı: **Wi-Fi'da boyut sınırı yok.** Gerekçe: klasörün içeriği tamamen kullanıcının kontrolünde; sınırın koruduğu durum (Finder'ın kendiliğinden büyük medya klasörlerine dokunması) bu kökle oluşmuyor, sınır ise kasıtlı büyük kopyaları engellerdi. Kalan bilinen davranış: klasörde büyük dosya varken Finder önizlemesi dosyanın tamamını indirir (Wi-Fi payı ~0,5–3 MB/s, akış yokken daha yüksek); bu sürede Finder o birimde yavaşlar, görüntü akışı hız kuralıyla (§5) korunur. Kullanıcıya öneri: klasörü liste görünümünde tutmak.

## Ek 2 (2026-10-06, cihaz denemesi T-270)

Çalışıyor (bağlama ~0,15 s, iki yönde kopya, çıkarma/yeniden açma, arka plan sonrası otomatik bağlama). Tavan (2,25 MB/s @ 30 Mbps) tablette doğru uygulanıyor; büyük kopya sırasında görüntü ölçümle bozuluyor (özellikle tablet→Mac), ama kullanıcı belirgin kötüleşme görmedi ve kopyalarken ekranı kullanmıyor → **tavan aynen kalır**, uyarlamalı kısma yok. §5'teki ölçüm bütçeleri bu kararla geçersiz.
