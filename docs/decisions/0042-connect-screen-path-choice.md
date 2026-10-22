# 0042 — Bağlantı ekranı: "Yerel ağ | Tailscale" seçimi, veri tasarrufu anahtarı, Bağlan/Durdur

- Tarih: 2026-10-22
- Durum: kabul (kullanıcı onayı 2026-10-22)
- Değiştirir: 0038 §1 (giriş ekranındaki "Uzaktan bağlan" düğmesi ve ayrı uzak adres / elle adres alanları). 0038'in uzak profili (§2), protokol (§3, §4), güvenlik (§5) ve zamanlamaları (§6) aynen geçerli.

## Bağlam

2026-10-22: kullanıcı "Manuel adres" alanına Mac'in Tailscale adresini (100.x) yazmıştı. Uygulama bu adresi sıradan Wi-Fi adresi sayıp evde de her açılışta oraya bağlandı. Tailscale kapanınca Mac'i ev ağında bulduğu halde (`discovery_resolved host=192.168.1.106`) kayıtlı 100.x adresinde ısrar etti ve bağlanamadı. Ses bozulmasında evde gereksiz Tailscale katmanının payı olabilir.

Kullanıcı: giriş ekranındaki "Uzaktan bağlan", "Uzak adres", "Manuel adres" kafa karıştırıyor. Uygulama açılır açılmaz bağlanıyor ve bağlanırken durdurma tuşu yok. Pratikte üç yol kullanıyor: evde yerel ağ, dışarıda mobil veriyle Tailscale (düşük veri), dışarıda sınırsız internetle Tailscale (tam kalite; "Manuel adres" ile yaptığı buydu). Evde Tailscale kullanmak için deneme dışında bir neden yok. "Evde / Dışarıda" ifadeleri garip, teknik ama doğru adlar tercih edildi.

## Karar

1. **Giriş ekranı:**
   - Segmentli seçim **"Yerel ağ | Tailscale"**.
   - **"Veri tasarrufu"** anahtarı yalnız Tailscale seçiliyken görünür.
   - Tek büyük **"Bağlan"** düğmesi. Bağlanma sürerken **"Durdur"** olur.
   - İkincil olarak "Mac'i uyandır" (yalnız Yerel ağ seçiliyken) ve "Ayarlar".
   - "Uzaktan bağlan", "Uzak adres", "Manuel adres" giriş ekranından kalkar.
2. **Yerel ağ:** Bugünkü yerel yol, tam kalite: USB (`adb reverse`) ve Bonjour bulma. Otomatik / Yalnız USB / Yalnız Wi-Fi ayarı ayarlarda kalır. Yerel ağ yolu **hiçbir zaman** elle yazılmış ya da Tailscale adresine bağlanmaz.
3. **Tailscale + Veri tasarrufu açık:** 0038 uzak oturumu (uzak profil, `link` uzak, WoL yok).
4. **Tailscale + Veri tasarrufu kapalı:** Tailscale adresine **normal (tam kalite) oturum**. Kullanıcının mod ve görüntü ayarları geçerli, WoL gönderilmez. Bu oturumun ayrı bit hızı sonra konuşulacak (açık nokta).
5. **Tailscale adresi:** Ayarlarda tek alan ("Tailscale adresi", IPv4 ya da MagicDNS adı, port isteğe bağlı). Tailscale seçiliyken adres yoksa "Bağlan" önce adresi sorar. "Manuel adres" kavramı kalkar.
6. **Açılışta bağlanma yok:** Uygulama açılınca, son seçim (yol ve tasarruf) hatırlanmış olarak **"Bağlan"ı bekler**. Hiçbir bağlantı ya da WoL denemesi yapmaz.
   - "Bağlan"dan sonra bugünkü davranış sürer: taşıma seçimi, bulma, kopunca yeniden bağlanma, Mac uyanınca bağlanma.
   - Bu davranış "Durdur"a ya da "Bağlantıyı kes"e kadar devam eder. Durdur bütün denemeleri ve WoL'u keser.
7. **Taşıma:** Elle adres kalkınca eski kayıtlı elle adres güncellemede şöyle taşınır: Tailscale adresi boşsa ve eski adres 100.64.0.0/10 içindeyse Tailscale adresi olur; aksi halde silinir.

## Sonuçlar

- Bugünkü hata (yerel yolda kayıtlı 100.x'e takılma) yapısal olarak ortadan kalkar. Yerel yol yalnız USB ya da Bonjour'un bulduğu adresi kullanır.
- Kullanıcı Tailscale'i evde de seçebilir (deneme için). Uygulama bunu engellemez, ama kendiliğinden de seçmez.
- 0038 §1'deki "elle adres, otomatik yeniden bağlanma … asla uzak profili seçmez" kuralı yeni biçimde korunur: uzak profil yalnız "Tailscale + Veri tasarrufu" ile seçilir.

## Açık nokta

- Tailscale tam kalite oturumunun bit hızı (ev internetinin yükleme hızı sınırlı olabilir): ayrı bir karar.
