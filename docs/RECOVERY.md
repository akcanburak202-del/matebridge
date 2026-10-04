# Kurtarma rehberi — "Tablet boş, Mac'e nasıl ulaşırım?"

> **Durum: TASLAK (2026-10-04).** Senaryolar henüz prova edilmedi (T-147). Her senaryonun "gerçekte olan" satırı prova sırasında doldurulur; o zamana kadar adımlar koddan ve NOTES'tan çıkarılmış beklentidir.

## Temel gerçekler

- **Mac başsız.** Fiziksel monitör ya da HDMI dummy yok. MateBridge oturumu yokken macOS'un gösterdiği tek ekran **1920×1080 başsız yer tutucu ekran**dır (`v0x756e6b6e/m0x76697274`, fiziksel değil). Parsec bu ekrana ulaşır.
- **Sanal ekran oturum bitince bekletilir.** Yakalama ve kodlama hemen durur, sanal ekran 10 sn daha yaşar (`MATEBRIDGE_DISPLAY_KEEP_S`, T-165), sonra kaldırılır ve macOS yer tutucuya döner. Yakalama ya da kodlayıcı hatasında ekran hemen kaldırılır.
- **Uzak yol: Parsec.** Mac'te Parsec host'u giriş öğesi olarak açılır. SSH ve Ekran Paylaşımı kullanılmıyor.
- **Son çare: HDMI kablosuyla monitör.** Parsec de ulaşamazsa Mac'e monitör ve klavye bağlanır.
- **FileVault kapalı, otomatik giriş açık** (`burakakcan`). Yeniden başlatmadan sonra Mac kendiliğinden oturum açar; MateBridge giriş öğesi olarak başlar.
- **Çökme sonrası otomatik yeniden başlatma yok** (T-202 bekliyor). Giriş öğesi yalnız oturum açılışında çalışır.
- **Tek kopya:** ikinci bir MateBridge açılırsa kendiliğinden kapanır (T-224). Menü çubuğunda iki simge görülmemeli.

## Senaryolar

Her senaryoda: **belirti → ilk hamle → olmazsa**.

### 1. MateBridge kapatıldı (menüden Çık)
- **Belirti:** tablette bağlantı koptu ekranı; 10 sn sonra Mac yer tutucu ekrana döner.
- **İlk hamle:** tabletten Parsec'e geç → Mac'te Spotlight/Finder ile MateBridge'i aç → tablette MateBridge'e dön.
- **Olmazsa:** HDMI monitör.
- _Prova:_ —

### 2. MateBridge çöktü
- **Belirti:** 1 ile aynı. Mac'te basılı tuş, düğme ya da kalem kalıp kalmadığı provada doğrulanacak (süreç ölünce bırakma mesajı gönderilemez).
- **İlk hamle:** 1 ile aynı. Mac'te takılı bir tuş varsa (ör. Cmd) Parsec'ten o tuşa bir kez bas.
- **Olmazsa:** HDMI monitör. Sık oluyorsa T-202 (otomatik yeniden başlatma) öne alınır.
- _Prova:_ —

### 3. Tablet uygulaması çöktü ya da kapandı
- **Belirti:** tablette uygulama yok. Mac tarafında 1,5 sn sonra bütün girdi bırakılır, 5 sn sonra bağlantı kapanır, sanal ekran 10 sn bekletilir.
- **İlk hamle:** tablette MateBridge'i yeniden aç. 10 sn içinde dönersen aynı sanal ekran kullanılır.
- _Prova:_ —

### 4. Ağ koptu (Wi-Fi gitti)
- **Belirti:** Otomatik bağlantıda kablo takılıysa oturum USB'ye geçer; kablo yoksa "bağlantı yok".
- **İlk hamle:** USB kablosunu tak; tablette "dosya aktarımı" seçimi istenirse seç.
- **Olmazsa:** tableti yeniden başlat; Mac tarafında Parsec ile Wi-Fi'yi kontrol et.
- _Prova:_ —

### 5. Ekran Kaydı izni gitti
- **Belirti:** tablette görüntü yok; Mac menüsünde "…then restart it" yazısı.
- **İlk hamle:** Parsec → Sistem Ayarları → Gizlilik → Ekran ve Sistem Sesi Kaydı → MateBridge'i aç → MateBridge'i yeniden başlat (izin yeniden başlatmadan sonra geçerli olur).
- _Prova:_ —

### 6. Erişilebilirlik izni gitti
- **Belirti:** görüntü var, kalem, klavye ve fare Mac'e işlemiyor (`input_gate accessibility=0`).
- **İlk hamle:** Parsec → Sistem Ayarları → Gizlilik → Erişilebilirlik → MateBridge'i aç. Yeniden başlatma gerekmez; MateBridge menüsünde "Sistem Ayarlarını aç" maddesi var.
- _Prova:_ —

### 7. Mac yeniden başladı (elektrik kesintisi dahil)
- **Belirti:** Mac açılırken tablette bağlantı yok.
- **Beklenen:** FileVault kapalı ve otomatik giriş açık olduğu için Mac oturum açar, MateBridge giriş öğesi olarak başlar, tablet bağlanır. Not: Mac elektrik kesildikten sonra kendiliğinden açılmaz (`autorestart 0`); güç düğmesine basmak gerekir.
- **Olmazsa:** Parsec (giriş ekranında da çalışıyorsa) → MateBridge'i aç; o da olmazsa HDMI monitör.
- _Prova:_ —

### 8. Oturum kapatılıp açıldı
- **Beklenen:** giriş öğesi MateBridge'i başlatır, tablet kendiliğinden bağlanır.
- _Prova:_ —

### 9. Mac uykuda ya da kilitli
- **Belirti:** tablette "Mac uyku modunda".
- **İlk hamle:** tablette MateBridge'i öne getir; tablet Mac'i uyandırır (~2 sn). Kilit ekranında parolayı tablet klavyesiyle yaz.
- _Prova:_ —

## macOS ya da HarmonyOS güncellemesinden sonra: 5 dakikalık kontrol

1. `host.log`'da sanal ekran 2800×1840 @60 ve @120 kuruldu, `mode_selected=true`.
2. Krita'da kalem: basınç, eğim, havada imleç.
3. İki parmak sıkıştırma ile yakınlaştırma.
4. Ctrl↔Cmd kısayolları (ör. Ctrl+C / Ctrl+V).
5. Bir uyku/uyanma.

Ekran kurulamıyorsa (özel API `CGVirtualDisplay` değişmiş olabilir) sonucu NOTES'a yaz ve dur.

## Son bilinen iyi sürüm çifti

| Tarih | macOS | HarmonyOS | Host SHA | APK SHA | `check.sh` |
|---|---|---|---|---|---|
| _prova sırasında doldurulur_ | 27.0.1 (26A434) | | | | |
