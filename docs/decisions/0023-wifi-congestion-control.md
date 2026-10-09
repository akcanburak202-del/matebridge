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
