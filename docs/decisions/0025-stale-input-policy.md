# 0025 — Ağ tıkanmasından sonra bayat girdi politikası

- **Durum:** önerildi
- **Tarih:** 2026-10-03

## Bağlam
Kaynak: dış mimari incelemesi 2026-10-03 (HEAD a30c769), M04 (tazelik yarısı) ve SE3. Doğrulama: `docs/reviews/2026-10-03/verify-G-input.md` (M04, ek 1–3, P-M04d). Rapordaki "0019" taslağı bu numarayla yeniden numaralandı.

Wi-Fi bir süre tıkanınca girdi geç ulaşıyor ve tam hâliyle geç uygulanıyor:
- **İstemci kuyruğu yaşı yalnızca girişte denetliyor.** `SendQueue` yaş sınırı (1 sn) yalnızca `offer` anında bakılıyor (`SendQueue.kt:25-36`).
- **Çekirdeğe yazılmış baytların yaş sınırı yok.** Kontrol soketi yalnızca `tcpNoDelay` ile açılıyor (`SessionController.kt:641`).
- **Gerçek sınır 5 sn.** Geç girdinin gerçek üst sınırı, host'un 5 sn'lik sessizlik kapanışı (PROTOCOL §6). PROTOCOL §4 "Kabul edilen davranış" ise 1 sn yazıyor (PROTOCOL.md:300). Bu metin T-172'de düzeltilir.
- **Mandaldan sonra da geç girdi geliyor.** 1,5–5 sn'lik bir tıkanmada release-all ve mandal devreye giriyor, ama ardından gelen tam tıklamalar, tuşlar ve `STROKE_START`'lı vuruşlar saniyeler sonra Mac'te oynatılabiliyor.
- **Host girdinin yaşını bilmiyor.** Mesajdaki `*_time_us` kullanılmıyor (PROTOCOL §7) ve host PING göndermiyor. Yaş ölçümünü T-171 ekler (host PING, yalnızca tanı).

Tuş tekrarı ayrı bir konu ve T-163'te çözülüyor: bağlantı sessizken host'un otomatik tuş tekrarı duraklatılır. Bu da 0003'e eklenen bir durdurma koşulu.

## Seçenekler
- **(a) Olduğu gibi kalsın.** Tıkanmadan sonra eski tıklama ve tuşlar geç uygulanır.
- **(b) Basılı tuşlar için istemciden canlılık mesajı.** Reddedildi: protokol anlamı ister ve yalnızca tuşları kapsar.
- **(c) Host'ta yaşa dayalı politika (önerilen).** Host'un ölçtüğü yaş T_stale'i aşarsa:
  - Hover ve göreli hareket en yeni duruma indirgenir.
  - Yeni basmalar ve onların eş bırakmaları **birlikte** yok sayılır: PEN `STROKE_START`, POINTER düğme basma kenarı, KEY DOWN, SCROLL/PINCH BEGAN. Mevcut KEY-DUP, mandal ve sahiplik kuralları bunları etkisiz kılar.
  - Uygulanmış bir basmanın bırakması **her zaman** uygulanır. Bırakma asla düşürülmez (AGENTS.md).
  - Saat farkı tahmini güvenilmezse (RTT dağılımı fazla geniş) politika kapalı kalır. Bu, hata durumunda açık kalma (fail-open) davranışıdır.

## Karar
Önerilen: **(c)**. T_stale başlangıçta 300 ms. Kesin değer T-171'in ölçtüğü yaş dağılımlarından seçilir. Uygulama ancak bu veri ve bu kararın kabulüyle başlar.

En büyük risk, saat farkı hatası yüzünden meşru girdinin düşmesi. Bu yüzden politika belirsizlikte kapalıdır ve fuzz testleri geçmeye devam etmelidir.

**Kullanıcı onayı bekliyor.** Kullanıcının cevaplaması gereken (manifest §5 soru 10): uzun bir Wi-Fi tıkanmasından sonra ~300 ms'den eski basmaların yok sayılmasını kabul ediyor musun? Bırakmalar her zaman uygulanır.

## Sonuçlar
- **Kazanılan:** tıkanmadan sonra saniyeler önceki tıklama, tuş ve vuruşlar Mac'te oynatılmaz. Girdi asla takılı kalmaz, çünkü bırakmalar korunur.
- **Kaybedilen:** tıkanma sırasında yapılan gerçek bir tıklama ya da tuş yok sayılabilir. Kullanıcı tekrar etmek zorunda kalır.
- **Kapıladığı kart:** T-199 (host bayat girdi politikası). T-171 (yaş verisi) ve T-175'e (girdi teslim zamanlaması) bağlı.
- **Mevcut kararlar:** 0003 bu kararla değişmez; tuş tekrarı durdurma koşulu T-163'te ayrıca eklenir. 0007'nin kalem teması kuralları korunur.
- **PROTOCOL.md (yalnızca metin):**
  - §4 "Kabul edilen davranış": bayat basma kuralı ve doğru üst sınır.
  - §7: yaş temelli politika ve fail-open davranışı.
  - Tel ve fixture'lar değişmez.
- **Tekrar düşünülür:**
  - T-171 verisi Wi-Fi'de anlamlı bir bayat girdi göstermezse karar düşer.
  - Saat farkı tahmini sık güvenilmez çıkarsa politika etkisiz kalır.
