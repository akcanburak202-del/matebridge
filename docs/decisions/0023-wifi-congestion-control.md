# 0023 — Wi-Fi tıkanıklığı TCP üzerinde çözülür: önce sabit Wi-Fi profili, gerekirse uçuştaki bayt bütçesi ve canlı bit hızı

- **Durum:** önerildi; düşük öncelik (Wi-Fi yedek yol, 2026-10-03)
- **Tarih:** 2026-10-03

## Bağlam
Kaynak: dış mimari incelemesi 2026-10-03 (HEAD a30c769), H03, X8, D6, A3, A4 ve LM7. Doğrulama: `docs/reviews/2026-10-03/verify-F-network.md` (H03, F-0, F-7, T-127 yeniden kapsamı). İki taslak (F-0 ve F-7) tek kararda birleştirildi.

Gerçekler:
- **Gecikme kayıptan değil kuyruktan geliyor.**
  - Wi-Fi'de tam ekran değişimleri havaya kare başına 100–450 KB gönderiyor. Kontrol srtt'si 20 ms'den 60–100 ms'ye çıkıyor ve 5 dakikada 13 ses kesintisi oluyor (NOTES.md:970-991).
  - Kontrol soketinde yeniden gönderim yok.
  - Kontrol VO, video VI sınıfında işaretli (T-124), ama sorun yine de oluyor.
- **Çekirdekte yalnızca gönderilmemiş baytlar sınırlı.** `TCP_NOTSENT_LOWAT` 128 KiB (`BsdTcpSocket.swift:372-382`). Gönderilmiş ama onaylanmamış ("uçuştaki") baytlar sınırsız: cwnd 2–13 MB. Büyük bir kare satır hızında yazılıyor (`:392-416`).
- **Bit hızı oturum içinde sabit.**
  - `MATEBRIDGE_WIFI_BITRATE_KBPS` yalnızca geliştirici ortam değişkeni (`TransportBitrate.swift:1-29`).
  - Wi-Fi'de de USB'deki varsayılanlar kullanılıyor: 60 fps'te 30 Mbps, 120 fps'te 60 Mbps (`StreamPrefsPolicy.swift:21-27`).
  - Bit hızı değişikliği boru hattını yeniden başlatıyor ve yeni keyframe istiyor (`StreamCoordinator.swift:373-389`). Bu yol uyarlama için kullanılamaz.
- **Ölçüm eksik ve karışık.** Ölçüm yalnızca Mac de Wi-Fi'deyken yapıldı (iki kablosuz atlama, DFS 160 MHz, `awdl0` açık). Mac Ethernet'teyken hiç tekrarlanmadı (T-127 adım 1 açık).
- **Bağlantı kapasitesi kodlayıcı hızı değil.** Ham bağlantı akış başına ~410 Mbit/s (NOTES.md:603-610). Gecikme, AP ve sürücü kuyruğundan geliyor (audit K2).

## Seçenekler
- **(a) Şimdi UDP ya da QUIC'e geç.** Reddedildi (A3/A4):
  - Kayıp yok, sorun kuyruk.
  - Parçalama, tıkanıklık kontrolü, nonce ve kurtarmanın birlikte tasarlanması gerekir.
- **(b) Adım 1: yalnızca host'ta sabit, temkinli bir Wi-Fi varsayılan bit hızı (önerilen ilk adım).**
  - Değer T-127 ölçümünden seçilir.
  - Kullanıcının `STREAM_PREFS` seçimi ve ortam değişkeninin önceliği değişmez (0013).
  - Tel değişmez.
- **(c) Adım 2, yalnızca (b) yetmezse:**
  - Videonun uçuştaki baytları `sbbytes` bütçesiyle sınırlanır.
  - Bit hızı oturum içinde canlı uyarlanır: hızlı in, yavaş çık. Bu `VTSessionSetProperty` ile yapılır, yeniden başlatma yolu kullanılmaz.
  - `STREAM_CONFIG.bitrate_kbps` artık "tavan" anlamına gelir. Host, yeni `config_id` olmadan bunun altında kodlayabilir.
- **(d) `STREAM_PREFS`'e ayrı bir Wi-Fi bit hızı alanı.** Reddedildi: tel değişikliği ve yeni fixture gerektirir, (b) ise aynı işi telsiz yapar.

## Karar
Önerilen: **(b), gerekirse ardından (c)**, ve TCP kalır. Hangi dalın seçileceği, T-127'nin üç topolojili temel ölçümünden sonra NOTES'a yazılır: "sabit profil yetiyor" ya da "uyarlamaya geç". Topolojiler:
1. USB;
2. Mac Ethernet'te, tablet Wi-Fi'de;
3. ikisi de Wi-Fi'de.

Bütçeler ölçümden **önce** yazılır. Öneri:
- 5 dakikada en çok 1 ses kesintisi;
- kontrol srtt p95 ≤ 40 ms;
- Wi-Fi'de yakalama→çözme p95 ≤ 70 ms.

**Kullanıcı onayı bekliyor.** Kullanıcı cevabı (2026-10-03): **Wi-Fi yedek yol kalır**, asıl yol USB. Bu yüzden H03 işi (T-127, T-178, T-195, T-196) düşük öncelikte; karar, T-127 ölçümü yapılınca yeniden sunulur. Kullanıcının cevaplaması gerekenler (manifest §5 soru 8):
1. Wi-Fi asıl yol mu olacak, yoksa yedek mi kalacak? Bu, H03 işinin önceliğini belirler.
2. Mac'i Ethernet'e bağlayıp ölçüm yapabilir misin?

## Sonuçlar
- **Kazanılan:** ucuz ve telsiz bir ilk adım. Uyarlama kodu ancak ölçüm gerektirirse yazılır. Ses ve girdi, video patlamalarının arkasında daha az bekler.
- **Kaybedilen:**
  - (b)'de Wi-Fi'de daha düşük bit hızı, yani hareketli görüntüde biraz netlik.
  - (c) gelirse anlık bit hızı yapılandırılandan düşük olabilir.
- **Kapıladığı kartlar:**
  - T-178: Wi-Fi varsayılan bit hızı, (b), T-127'ye bağlı.
  - T-195: saf tıkanıklık denetleyicisi, (c).
  - T-196: denetleyicinin gönderim kapısına ve kodlayıcıya bağlanması, (c).
  - Kapılı olmayanlar: T-176 (IDR geri beslemesi) ve T-177 (canlı bit hızı ayarı) karar beklemez.
- **Mevcut kararlar:** 0013'e Wi-Fi varsayılan bit hızı eklenir. Öncelik sırası (ortam değişkeni > kullanıcı > mod varsayılanı) aynı kalır.
- **PROTOCOL.md:**
  - (b) seçilirse değişmez.
  - (c) seçilirse yalnızca §0x03 `bitrate_kbps` metni değişir ("tavan; host tıkanıklıkta altında kodlayabilir"). Alan, boyut ve fixture değişmez.
- **Diğer belgeler:**
  - PLAN.md:74 ve :126 (UDP'ye geçiş ve karşılaştırma notları) güncellenir.
  - T-127'nin eski 3. adımı bu kararla geçersiz olur.
- **Tekrar düşünülür:** uyarlamadan sonra p99 hâlâ yeniden gönderimlerle belirleniyorsa datagram taşımaya yeniden bakılır.

**Ek (2026-10-08):** Kullanıcı kararı 2026-10-08 (T-297 ortak ayıklaması, `docs/reviews/2026-10-08/simplification.md`):
- `MATEBRIDGE_BITRATE_STEP` ve yalnız onun ulaştığı canlı bit hızı ayarlayıcı zinciri kaldırılır (`VideoPipeline.setTargetBitrate` hiç çağrılmıyordu).
- "Gerekirse canlı bit hızı" dalı yeniden açılırsa kod git geçmişinden (T-177) geri gelir.
- `MATEBRIDGE_RATE_WINDOW_MS` şimdilik kalır: kare boyutu tavanı ölçümü (T-298 EN9) bekleniyor.

**Ek (2026-10-09): (c) dalı yeniden açıldı.**
- **Neden:** 2026-10-04'te "sabit profil yeterli" denip T-195/T-196 uygulanmadan kapatılmıştı. O günden beri Wi-Fi günlük yol oldu (kullanıcı oyunları Wi-Fi'de oynuyor). 2026-10-08 akşamından beri tablete giden WLAN atlaması kapasiteye yakın: Oyun 60 Mbps'te kuyruk gecikmesi, takılmalar ve üç kopma; 30 Mbps'te temiz (NOTES 2026-10-08 21:49, 22:37; 2026-10-09 16:50). Kapasite ortamla değişiyor; sabit bir Wi-Fi varsayılanı ya iyi günlerde netlik kaybettirir ya kötü günlerde takılır.
- **Kullanıcı onayı (2026-10-09):** "önce DSCP (T-326), sonra uyarlamalı bit hızı" yönü onaylandı.
- **Kartlar:** T-327 (saf denetleyici, T-195 tasarımı + 2026-10-09 Oyun izinden altın tekrar), T-328 (gönderim kapısı + T-177 canlı bit hızı ayarlayıcısının git geçmişinden geri gelmesi, `transport=network`, anahtar varsayılan kapalı). Varsayılan açma, cihaz A/B'sinden sonra ayrı ek ile.
- **Tavan:** kullanıcının/modun bit hızı tavan kalır (0013 önceliği değişmez); denetleyici yalnız altına iner. PROTOCOL §0x03 metin değişikliği T-328 birleşirken orkestratör tarafından yapılır; bayt ve fixture değişmez.
- T-326 (açık DSCP) bağımsızdır: ses/kontrolü AP'de videodan ayırır, video kuyruğunu küçültmez. A/B'ler ayrı kollarla ölçülür.
- **Durum (2026-10-09 akşam):** T-326 (`MATEBRIDGE_IP_TOS`) ve T-327/T-328 (`MATEBRIDGE_WIFI_ADAPT`) birleşti; host `61718882` kurulu. Kullanıcı kararı: ikisi de **varsayılan kapalı kalır**; cihaz A/B'si ve tcpdump doğrulaması şimdilik yapılmadı. Yeniden açılırsa önce tcpdump (DSCP'nin IPv4 başlığına ulaştığı), sonra Oyun 60 Mbps A/B.

**Ek (2026-10-25): WIFI_ADAPT v2 — yalnız bit hızı, doğrulanmış kanıt (T-379).**
- **Neden:** v1 (T-327/T-328) 2026-10-23 TotK'de çöktü: tek başına srtt fazlası düşüşü tetikledi, ×0,7 adımlar 1,2 sn'de 12 Mbps tabanına indi, bit hızına bağlı gönderim kapısı daralıp kuyruk düşüşü → zorunlu IDR döngüsü kurdu (NOTES 2026-10-23; astra incelemesi `docs/reviews/2026-10-25/astra-wifi-game.md` öneri 1). T-370 (kodlama öncesi ezme) ve T-378 (busy'de kare tutma, tek sınırlı toparlanma IDR'ı) önkoşulları sağladı.
- **Yeni kanıt (2026-10-25 20:55:36–41, NOTES):** kullanıcının gördüğü takılmada srtt 4–11 ms (fazla yok), retx 1–3 paket/sn (%0,1 altı), ama video yazımı tekrar tekrar ~200 ms bloklandı (`write_ms` max 220, `queue_ms` p95 ~200) ve `unacked` = `cwnd`. Yani bu WLAN'da asıl sinyal **ilerlemeyen gönderim**dir; srtt ve kayıp oranı tek başına bu olayı yakalamaz. Aynı gün temiz oturumda (14:25–15:11) 36 dk'da takılma yok.
- **Kapsam:** yalnız `transport=network`, ana video akışı. Tavan = kullanıcının/modun bit hızı (0013 önceliği aynı). Anahtar aynı: `MATEBRIDGE_WIFI_ADAPT=1`, varsayılan kapalı; v2, v1 denetleyicisinin yerini alır (v1 kodu ve **ek gönderim kapısı kaldırılır**). Açık anahtarla değişen tek şey canlı kodlayıcı bit hızıdır (`VTSessionSetProperty`; yeniden başlatma, IDR, ekran değişimi, kapı daraltma yok). Tel değişmez; PROTOCOL §0x03 "tavan" metni 2026-10-09 ekindeki gibi.
- **Örnekleme:** 100 ms. Sinyaller:
  - **S (stall):** devam eden video yazımı ya da kuyruk başındaki karenin yaşı ≥ 150 ms ve bu sürede yazılan bayt ilerlemiyor (ilerleyen büyük keyframe yazımı stall sayılmaz, bir yerleşme aralığı tanınır).
  - **D (gecikme):** srtt − taban ≥ 20 ms; taban = son 30 sn'de boşalan (birikimsiz) örneklerin düşük yüzdeliği, bağlantı değişince sıfırlanır; kalıcı tıkanıklık taban olarak öğrenilmez.
  - **L (kayıp):** kayan 1 sn'de retx/tx ≥ %1 ve ≥ 4 paket.
  - **B (birikim boşalmıyor):** `sndbuf_bytes`/bekleyen bayt 250 ms boyunca düşmüyor.
- **Karar yasası** (ilk kalibrasyon; cihazda doğrulanmamış sabitler, tek yerde sabit olarak tanımlanır):
  - **Ağır:** son 2 sn'de ≥ 2 ayrı S olayı, ya da tek S ≥ 500 ms, ya da 5 örneğin ≥ 3'ünde D ≥ 50 ms ve B. Yanıt **×0,7**, en sık 500 ms'de bir.
  - **Orta:** 5 örneğin ≥ 3'ünde D ≥ 20 ms ve B, ya da L ve B. Yanıt **×0,85**, en sık 750 ms'de bir.
  - Her adımdan sonra **taze kanıt** gerekir (aynı olay ikinci kez sayılmaz).
  - **Tek başına** S, D ya da L (yukarıdakiler sağlanmadan): düşüş yok, yalnız 2 sn yukarı adım beklemesi.
  - **Taban:** normal taban **30 Mbps** (tavan daha düşükse tavan). **Acil taban 20 Mbps** yalnız 30'dayken 2 sn daha ağır kanıt sürerse. Tabanda kapı sıkılaşmaz, IDR üretilmez.
  - **Çıkış:** 3 temiz saniyeden sonra **+2 Mbps/sn**, tavana kadar. Boşta tavana sıçrama yok.
- **Kayıt:** `video ev=adapt` (her değişim: `from_kbps to_kbps reason=severe|moderate|recover|emergency evidence=S,D,L,B`) ve saniyelik durum alanları; `sent_kbps`'in `bitrate_set`'i izlediği cihazda doğrulanır.
- **Varsayılan açma:** cihaz A/B'si (aynı gün, anahtar açık/kapalı, Oyun 60) ve ayrı ek ile. Ölçüt: takılma (`cap_dec_ms` > 150 ve gösterim boşlukları) azalmalı, temiz oturumda gereksiz düşüş ≤ 1/10 dk, tabana kilitlenme yok, IDR artmıyor.
- **Beklenti (çıkarım):** radyo tıkanması sırasında donmayı önleyemez (TCP eksik baytı bekler), ama tıkanma tekrarlarken arkada biriken baytı yarıya indirip toparlanmayı ve ezilen kare sayısını azaltır. Kullanıcı onayı: 2026-10-25 ("Evet").
- **Uygulama notları (T-379 birleşmesi, 2026-10-25):** B eşiği = mevcut hedef hızın 20 ms'si (en az 32 KiB), 300 ms boyunca düşmüyor (sabit 32 KiB temiz oturumda 50 düşüş verdi). D tabanı = 30 sn içinde gönderim arabelleği < 32 KiB olan örneklerin p10'u; 20 örnekten azsa D yok sayılır. S yazıcı tarafında ölçülür (bayt ilerleme damgası; kuyruk başı beklemesi dahil), olaylar kendi zamanlarıyla taşınır. Acil taban yalnız o anki taze ağır kanıtla. Tavan bağlantı başına sabit (bit hızı değişimi zaten akışı yeniden başlatıyor). İz tekrarı: 20:55 olayı 60→42→30, temiz 46 dk'da 3 düşüş (en düşük 51 Mbps). Codex 6 tur.
