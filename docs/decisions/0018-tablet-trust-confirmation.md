# 0018 — Tablet tarafında güven onayı ve yalnızca kullanıcının başlattığı eşleşme

- **Durum:** önerildi
- **Tarih:** 2026-10-03

## Bağlam
Kaynak: dış mimari incelemesi 2026-10-03 (HEAD a30c769), H01, X1, D2 ve F2 (kısmen). Doğrulama: `docs/reviews/2026-10-03/verify-A-security.md` (H01, WI-0) ve `verify-A2-adversarial.md` §1–2. Bulgu doğrulandı (High). Bu bir uygulama hatası değil, tasarım açığı: davranış PROTOCOL §9 ve T-044'te bilerek yazıldı.

Karar 0010, eşleşme kodunun iki tarafı da koruduğunu varsaydı, ama kodu yalnızca Mac denetliyor:
- Tablet, PAIRING'deki ilk HELLO_ACK'te yeni anahtarı **hemen** saklıyor, eskisinin yerine (`SessionController.kt:663-676`, `Handshake.kt:67-77`, `PairKeyStore.kt:38-41`). Bu, Mac ya da kullanıcı bir şey yapmadan olur.
- Mühürlü her `ACCEPTED` oturumu açıyor (`SessionMachine.kt:300-326`). Tablette hiçbir yerel koşul denetlenmiyor. Kod ekranı yalnızca bilgi veriyor ve onay ya da iptal düğmesi yok (`MainActivity.kt:2053-2070`).

Sonuç olarak PAIRING'e cevap veren her uç, yerel onay olmadan şunları alır:
- bütün PEN, KEY ve POINTER mesajlarını (fiziksel tuş kodları, yani yazılan şifreler dahil);
- panoyu iki yönde;
- dosya paylaşımı açıksa `FILES_INFO` jetonunu.

Saldırgan şunlardan biri olabilir:
- Wi-Fi'de sahte Bonjour hizmeti ya da hatırlanan IP'ye cevap veren biri. Tablet bulduğu her hizmete seçim ekranı göstermeden bağlanıyor (`MainActivity.kt:1803-1809`, `MacDiscovery.kt:105-122`). Bu yalnızca Wi-Fi yolunda, tablet Searching ya da Disconnected durumundayken olur.
- Tablette `127.0.0.1:47001`'i tutan bir uygulama (yalnızca INTERNET izni yeter). Bu uygulama jetonla bütün `/sdcard`'a erişir, yani karar 0015 madde 3'ün güvencesi bozulur.

Aynı `host_id` kullanan sahte bir uç saklı anahtarı da ezer. Gerçek Mac'e sonraki bağlantı bitmeyen bir PROTOCOL_ERROR döngüsüne girer.

Ek bulgu (A2): AUTO modunda USB'ye taşınan aday bağlantı, şifresiz PAIRED/ACCEPTED cevabıyla terfi ediyor (`SessionMachine.kt:463`, `:492-511`). Bu bir DoS açığı.

## Seçenekler
- **(a) Olduğu gibi kalsın.** İş yok, ama açık kalır.
- **(b) Anahtar, yerel onay ve host'un ACCEPTED'ı birlikte gelince saklansın** (incelemenin önerisi). Basit. Ancak kullanılan Parsec akışını bozar: başsız Mac'te kullanıcı kodu görür, Parsec'e geçer, Mac'te onaylar ve döner. Bu sırada bağlantı kopar ve tablet ACCEPTED'ı hiç almaz (T-043/T-044, NOTES 2026-09-30).
- **(c) Bekleyen kayıt, yerel onay ve kullanıcının başlattığı eşleşme (önerilen):**
  - Yeni anahtar, kodla birlikte (Keystore ile sarılı, asla loglanmaz) **bekleyen** bir kayıtta tutulur. Güvenilen anahtara dokunulmaz.
  - Kullanıcının tablette "Kodlar aynı — Güven" demesi, bekleyen kaydı tek adımda güvenilen anahtara çevirir. Bu, Parsec'e geçmeden önce ya da dönüşte, saklı kodu gösteren bir istemle olabilir.
  - Tablet oturumu ancak iki koşul birlikteyken kabul edilmiş sayar: host kabul etti (ACCEPTED ya da sonraki bir PAIRED el sıkışması) ve kayıt yerel olarak güvenilir. O zamana kadar yalnızca PING gider. STREAM_PREFS, FILES_INFO ve girdi gitmez, gelen CLIPBOARD uygulanmaz.
  - İptal, zaman aşımı (2 dk) ya da REJECTED bekleyen kaydı siler. PAIRED el sıkışması onaylanmamış bir anahtarı asla kullanmaz.
  - **Eşleşme her zaman kullanıcıyla başlar.** Keşif, saklı uç ya da USB yoklaması ile açılan bağlantıda PAIRING cevabı gelirse bağlantı kesilir ve "Yeni Mac bulundu / Mac yeniden eşleşmek istiyor — Eşleş" gösterilir. Normal PAIRED yeniden bağlanma sessiz kalır.
  - Tablete "Bu Mac'i unut" eklenir.
  - Taşıma adayı, ancak ilk doğrulanmış host kaydından sonra terfi eder.

## Karar
Önerilen: **(c)**. Tel biçimi değişmez. Mesaj, alan, fixture ve `crypto_vectors.json` aynı kalır. **Kullanıcı onayı bekliyor.**

Kullanıcının cevaplaması gerekenler (manifest §5 soru 3):
1. Parsec/onay-sonrası akışı kalsın mı? Önerilen tasarım onu koruyor: kodu tablette Parsec'e geçmeden önce ya da döndükten sonra onaylarsın.
2. Her eşleşmenin tablette bir dokunuşla ("Yeni Mac bulundu — Eşleş") başlamasını kabul ediyor musun? Bu, Mac'te "Onaylı cihazları unut" dedikten sonra da geçerli.

## Sonuçlar
- **Kazanılan:** sahte host ya da yerel uygulama girdi, pano ve dosya jetonu alamaz, saklı anahtarı da ezemez. Karar 0015 madde 3'ün güvencesi geri gelir.
- **Kaybedilen:** her eşleşmede tablette fazladan bir ya da iki dokunuş. Tablet eşleşmeyi bıraktığında Mac'te onay penceresi bir an görünebilir.
- **Kapıladığı kartlar:** T-150, T-151, T-153, T-156; aygıt kabulü T-157. T-150 ve T-151 arka arkaya birleştirilir, aralarında APK kurulmaz. T-152 (host önce kanıt ister) karar gerektirmez, ama aynı PROTOCOL §3 değişikliğiyle birlikte yürür.
- **Mevcut kararlara etkisi:**
  - 0010 kısmen değişir: yalnızca istemci tarafındaki eşleşme davranışı. Durum notu "kısmen 0018 ile değişti" olur.
  - T-044'ün "ilk ack'te hemen sakla" davranışı kalkar.
- **PROTOCOL.md (yalnızca metin, orkestratör):**
  - §3 adım 3: istemci, PING dışında bir şey göndermeden önce yerel onayı da bekler.
  - §9 "Eşleşme" maddeleri 1 ve 3.
  - §9 "Bağlantı koptuktan sonra onay" (1) ve (3).
  - `gen.py --check` yeşil kalır.
- **Tekrar düşünülür:** birden fazla Mac ya da tablet desteklenirse, Wi-Fi üzerinden uzaktan eşleşme istenirse, ya da host kimliği için sertifika veya pin modeli gelirse.
