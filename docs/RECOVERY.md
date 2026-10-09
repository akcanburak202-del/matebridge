# Kurtarma rehberi — "Tablet boş, Mac'e nasıl ulaşırım?"

> **Durum: TASLAK, hiçbir senaryo henüz prova edilmedi (T-147, 2026-10-09).** Adımlar koddan (HEAD `2c84c5de`), NOTES'tan ve salt okunur Mac sorgularından çıkarıldı. Her senaryodaki _Prova_ satırı kullanıcı denedikten sonra gerçek sonuçla doldurulur; o zamana kadar "henüz prova edilmedi" kalır.

## Temel gerçekler (2026-10-09 kontrolü)

- **Mac başsız.** Fiziksel monitör ve HDMI dummy yok: `system_profiler SPDisplaysDataType` yalnız **1920×1080 başsız yer tutucu ekranı** listeliyor (`v0x756e6b6e/m0x76697274`, fiziksel monitör değil). MateBridge sanal ekranı yokken macOS'un gösterdiği tek ekran bu.
- **Uzak yol yalnız Parsec.** Uzak Oturum (SSH) **kapalı** (22 numaralı port kapalı, `sshd` yüklü değil), Ekran Paylaşımı **kapalı** (5900 kapalı). Parsec.app kurulu ve Giriş Öğeleri'nde kayıtlı, ama kontrol anında Parsec host süreci **çalışmıyordu** (yalnız Apple'ın `parsecd`'si vardı). Provada ilk iş: Parsec'in Mac'te gerçekten açılıp açılmadığına bak.
- **Son çare: Mac'e HDMI ile monitör ve klavye bağlamak.**
- **FileVault kapalı, otomatik giriş açık.** Yeniden başlatmadan sonra Mac kendiliğinden oturum açar; yerel klavye gerekmez. Elektrik kesilince Mac kendiliğinden açılmaz (`pmset autorestart 0`): güç düğmesi gerekir.
- **Sanal ekran oturum bitince 10 sn bekletilir** (`MATEBRIDGE_DISPLAY_KEEP_S`, varsayılan 10, T-165). Yakalama ve kodlama hemen durur, sanal ekran 10 sn yaşar, sonra kalkar ve Mac yer tutucuya döner (Parsec buna ulaşır). Kalıcı bekletme ayarı henüz yok (T-167 bekliyor). Yakalama ya da kodlayıcı hatasında ekran hemen kalkar.
- **Çökme sonrası otomatik yeniden başlatma yok** (T-202 bekliyor). Giriş öğesi (`SMAppService.mainApp`, kayıt T-148 ile başarana kadar her açılışta denenir) yalnız oturum açılışında çalışır. Tek istisna: host kendi takılmasını görürse 30 sn sonra kendini yeniden başlatır (aşağıda, senaryo 3).
- **Tek kopya kuralı (T-224):** ikinci MateBridge, eskisi 5 sn içinde kapanmazsa kendiliğinden çıkar. Yani takılı ama canlı bir host varken `open` hiçbir şey yapmaz; önce eskisini sonlandır.
- Kapatma sinyalleri (`kill`, `SIGTERM`, `SIGHUP`) ve menüden Quit temiz kapanır ve girdiyi bırakır; `kill -9` ve gerçek çökme bırakamaz.

## Senaryolar

Her senaryoda: **belirti → ilk hamle → olmazsa**. Parsec adımlarında tabletteki Parsec'e geçmek MateBridge'i arka plana atar; tablet BYE gönderir ve sanal ekran 10 sn sonra kalkıp yer tutucuya döner. Parsec'te ekran gelmezse 12 sn bekle.

### 1. MateBridge menüden Çık ile kapatıldı
- **Belirti:** tablette "Bağlantı yok…" ve yeniden deneme sayacı; Mac yer tutucuya döner.
- **İlk hamle:** Parsec → Mac'te Spotlight ile MateBridge'i aç → tablette MateBridge'e dön (otomatik yeniden dener).
- **Olmazsa:** HDMI monitör.
- _Prova: henüz prova edilmedi._

### 2. MateBridge çöktü (`kill -9` ile taklit)
- **Belirti:** 1 ile aynı. Süreç ölürse "bırak" mesajı gönderilemez: Mac'te basılı kalmış tuş, düğme ya da kalem teması olabilir (örn. Cmd).
- **İlk hamle:** 1 ile aynı. Takılı tuş varsa Parsec'ten o tuşa bir kez basıp bırak.
- **Olmazsa:** HDMI monitör. Sık oluyorsa T-202 (otomatik yeniden başlatma) öne alınır.
- _Prova: henüz prova edilmedi (takılı girdi kalıp kalmadığı ölçülecek)._

### 3. MateBridge takıldı (süreç canlı, yanıt yok)
- **Belirti:** tablette görüntü donuk ya da "Bağlantı yok…"; `host.log`'da `ev=coordinator_stall`.
- **Beklenen (T-325, donanımda denenmedi):** 3 sn'de uyarı, 10 sn'de oturumlar kapatılır ve yeni bağlantı reddedilir, 30 sn'de ve yalnız bütün girdi bırakılmışsa host kendini yeniden başlatır. Girdi bırakılamıyorsa yeniden başlatmaz, her 5 sn yeniden dener.
- **İlk hamle:** 1 dakika bekle. Gelmezse Parsec → Etkinlik Monitörü'nde MateBridge'i Zorla Bırak → MateBridge'i aç (tek kopya kuralı yüzünden önce eskisi gitmeli).
- _Prova: henüz prova edilmedi (zorla üretmek için güvenli bir yol yok)._

### 4. Tablet uygulaması çöktü ya da kapandı
- **Belirti:** tablette uygulama yok. Mac'te bağlantı kopunca girdi bırakılır; sessizlikte 1,5 sn'de bırakma, 5 sn'de bağlantı kapanışı. Sanal ekran 10 sn bekletilir.
- **İlk hamle:** tablette MateBridge'i aç. 10 sn içinde dönersen aynı sanal ekran kullanılır, pencereler yerinde kalır.
- _Prova: henüz prova edilmedi._

### 5. Ağ koptu (Wi-Fi gitti)
- **Belirti:** AUTO modda USB'de iken kablo çekilirse oturum Wi-Fi'ye düşer; Wi-Fi'de iken kablo takılırsa oturum USB'ye taşınır (geçiş süresi ölçülecek). İkisi de yoksa "Bağlantı yok…".
- **İlk hamle:** USB kablosunu tak. Kablo çekilince `adb reverse` tünelleri de gider; Mac menüsünde "USB: tüneller hazır" yazısını bekle (USB modu açık olmalı).
- **Olmazsa:** tableti yeniden başlat; Mac'in Wi-Fi'sini Parsec ile kontrol et.
- _Prova: henüz prova edilmedi (kablo takılıyken değil, takılı değilken Wi-Fi'de başla)._

### 6. Ekran Kaydı izni gitti
- **Belirti:** tablette görüntü yok; Mac menüsünde "Screen Recording permission is not granted … then restart it".
- **İlk hamle:** Parsec → Sistem Ayarları → Gizlilik ve Güvenlik → Ekran ve Sistem Sesi Kaydı → MateBridge'i aç → **MateBridge'i yeniden başlat** (izin yeniden başlatmadan sonra geçerli olur).
- _Prova: henüz prova edilmedi._

### 7. Erişilebilirlik izni gitti
- **Belirti:** görüntü var, kalem/klavye/fare Mac'e işlemiyor (`input_gate accessibility=0`); menüde "Erişilebilirlik izni gerekli".
- **İlk hamle:** menüden "Sistem Ayarları'nı aç…" → Erişilebilirlik → MateBridge'i aç. Yeniden başlatma gerekmez (menü açılınca izin yeniden okunur).
- _Prova: henüz prova edilmedi._

### 8. Mac yeniden başladı (elektrik kesintisi dahil)
- **Belirti:** Mac açılırken tablette bağlantı yok.
- **Beklenen:** oturum otomatik açılır, MateBridge giriş öğesi olarak başlar, tablet kendiliğinden bağlanır. Elektrik kesintisinde önce güç düğmesine bas.
- **Olmazsa:** Parsec (Parsec'in oturum açılmadan, giriş ekranında çalışıp çalışmadığı doğrulanmadı) → MateBridge'i aç. Parsec de yoksa HDMI monitör.
- _Prova: henüz prova edilmedi (Parsec ve MateBridge'in oturum açılışında gerçekten başladığı doğrulanacak)._

### 9. Oturum kapatılıp açıldı
- **Beklenen:** giriş öğesi MateBridge'i başlatır, tablet kendiliğinden bağlanır.
- _Prova: henüz prova edilmedi._

### 10. Mac uykuda ya da kilitli
- **Belirti:** tablette "Mac uyku modunda".
- **İlk hamle:** tablette "Mac'i uyandır" (Wake-on-LAN) ya da Mac uyanıksa "Bağlan"; Mac ~2 sn'de uyanır. Kilit ekranında parolayı tablet klavyesiyle yaz (NOTES 2026-10-02: çalışıyor).
- _Prova: uyku/uyanma 2026-10-02 donanımda görüldü; bu rehberin adımları olarak henüz prova edilmedi._

### 11. Video yeniden kurulamıyor ("Görüntü durdu")
- **Belirti:** tablette "Görüntü durdu — Kalem ve klavye Mac'e gönderilmiyor"; `host.log`'da `pipeline_failed`, `pipeline_breaker`. Kalıcı medya hatasında host yeniden kurmayı 10 → 20 → 30 sn bekleterek reddeder (T-293), tablet geri çekilerek dener (T-294).
- **İlk hamle:** tablette "Yeniden dene"; olmazsa bağlantıyı kes/bağlan. Mac uyanınca ve mod değişince kesici sıfırlanır.
- _Prova: henüz prova edilmedi._

## 5 dakikalık kontrol (macOS ya da HarmonyOS güncellemesinden sonra)

Başlık için salt okunur: `./scripts/device-smoke.sh --header-only`.

1. `host.log`: sanal ekran 2800×1840 @60 ve @120 kuruldu, `mode_selected=true`.
2. Krita'da kalem: basınç, eğim, havada imleç.
3. İki parmak sıkıştırma ile yakınlaştırma.
4. Ctrl↔Cmd kısayolları (Ctrl+C / Ctrl+V).
5. Bir uyku/uyanma.
6. Menüde Sürüm satırı ile tabletteki Sürüm satırı aynı SHA'yı göstermeli.

Ekran kurulamıyorsa (özel API `CGVirtualDisplay` değişmiş olabilir) sonucu NOTES'a yaz ve dur; yedek yok.

## Son bilinen iyi sürüm çifti

| Tarih | macOS | HarmonyOS | Host SHA | APK SHA | `check.sh` |
|---|---|---|---|---|---|
| 2026-10-09 | 27.0.1 (26A434) | 4.3.0.145 (C432E1R1P2) | `ba964b63` | `ba964b63` | CHECK_RESULT_PLACEHOLDER |

Sürüm çifti 2026-10-08 20:55'ten beri tablette/Mac'te kurulu olan çifttir; kullanıcı onayı ve 5 dakikalık kontrol bu tarih için henüz yapılmadı. Bu SHA'dan sonraki tek değişiklik docs/NOTES.md'dir. Güncelleme sonrası satırı yenisiyle değiştirme, altına ekle.
