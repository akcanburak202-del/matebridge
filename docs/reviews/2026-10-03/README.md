# Dış mimari inceleme (2026-10-03) — kodla doğrulama özeti

- **İncelenen:** başka bir modelin yazdığı 25 sayfalık Türkçe rapor, "Mac mini + MatePad Pro — Bağımsız mimari ve sistem incelemesi", `main @ a30c769`. PDF repoda değil.
- **Doğrulama:** aynı commit üzerinde, Mac ve tablete erişim olmadan, bulut ortamında yalnızca okuyarak yapıldı. Swift ve Android derlenmedi, cihaz testi yapılmadı. Yalnız `protocol/fixtures/gen.py --check` çalıştırıldı ve geçti.
- **Yöntem:**
  1. Rapor numaralı ~150 maddelik bir kontrol listesine çevrildi (`claims.md`, sonunda ek O1–O18).
  2. Sekiz ajan maddeleri alan alan kodla tek tek karşılaştırdı (`verify-A` … `verify-H`).
  3. Güvenlik bulgularını ayrı bir ajan çürütmeye çalıştı (`verify-A2-adversarial.md`).
  4. Bir denetçi ajan PDF'i baştan sona tarayıp kaçan madde ve çelişki aradı (`coverage-audit.md`).
  5. Önerilen işler tek listede birleştirildi (`manifest.md`), sonra kartlar ve karar taslakları yazıldı.

## Genel hüküm

Raporun ana değerlendirmesi doğru. MateBridge donanımda ciddi biçimde denenmiş, kişisel kullanımda işe yarayan bir beta. Baştan yazmak gerekmiyor. Önce güven sınırı, video sağlığı, sanal ekranın sürekliliği ve uçtan uca gerçek ölçüm ele alınmalı, Wi-Fi bundan sonra gelmeli.

Rapordaki **15 bulgunun hiçbiri yanlış çıkmadı.** Bazılarının etkisi raporun dediğinden büyük, bazılarınınki küçük çıktı. Birkaçı da projede zaten bilinen ya da bilerek ertelenmiş konulardı. Doğrulama sırasında raporun görmediği yeni sorunlar da bulundu (aşağıda).

## Bulgu bulgu sonuç

| No | Raporun dediği | Doğrulama | Not |
|---|---|---|---|
| H01 | Eşleşmede güvenilen Mac anahtarı sessizce değişebiliyor | **Doğru, raporun dediğinden ciddi** | Ayrıntısı tablonun altında. |
| H02 | Decoder vazgeçince input açık kalıyor | **Doğru, boşluk daha geniş** | Vazgeçme yalnızca log'a yazılıyor. Input'u kapatan ya da yeniden bağlanan başka bir yol yok. Görüntü donukken saniyede ~2 config+keyframe isteği gidiyor. Otomatik yeniden bağlanmada kare sayacı sıfırlanmadığı için input, yeni oturumun ilk karesinden önce açılabiliyor. T-028'deki "kare geliyor ama hiç çözülmüyor" durumunda vazgeçme hiç tetiklenmiyor. |
| H03 | Wi-Fi'de yalnız uygulama kuyruğunu sınırlamak yetmiyor | **Doğru, bir düzeltmeyle** | Video gönderimi kernel'deki *gönderilmemiş* baytı zaten sınırlıyor (`TCP_NOTSENT_LOWAT`). Raporun "yalnız uygulama tarafı" demesi eksik. Asıl eksik: yolda olan baytlar, srtt ve otomatik bit hızı kontrolü yok. Bit hızı değişince yakalama ve encoder yeniden başlıyor. T-127 işin ~%40'ını zaten kapsıyordu; yeniden kapsamlandı. |
| H04 | Sanal ekran bağlantı kopunca 10 sn sonra kalkıyor | **Doğru** | Tablet ekranı kapanınca ya da arka plana geçince BYE gidiyor ve ekran kalkıyor. Bekleme süresince yakalama ve encode çalışmaya devam ediyor. Rapor ikinci bir kapanma yolunu atlamış: yakalama ya da encoder hata verirse ekran anında kalkıyor (Mac uykusunda muhtemelen her seferinde). Ekranı 10 sn'de kaldırmak şu an aynı zamanda kurtarma yolu, çünkü pencereler başsız 1920×1080 ekrana dönüyor. |
| H05 | Gösterilen gecikme uçtan uca değil | **Doğru** | Tabletteki "gecikme", yakalama damgasından decoder çıkışına kadar ölçülüyor. Pacing, bırakma ve panel dışarıda kalıyor. Negatif değerler sıfıra kırpılıyor. 120 Hz'de yalnız pacing'in p50'si 13–17 ms, yani 10,6 ms'lik başlık değerinden büyük. Wire'daki damga host iz başlangıcından ~6,6 ms sonra, dolayısıyla tablet ~6,6 ms eksik gösteriyor. |
| M01 | Video okuyucu oturum neslini kontrol etmiyor | **Doğru** | Host her oturuma `configID = 1` ile başlıyor, tablet de `currentConfigId`'yi sıfırlamıyor. Bu yüzden oturumlar arasında config kontrolü fiilen hiçbir şeyi korumuyor. Pratikte nadir; asıl risk USB↔Wi-Fi geçişinde. |
| M02 | Encoder slot ayırma ile gerçek VT çağrısı aynı sırada değil | **Doğru, öncelik Düşük–Orta** | En az 6 farklı thread `send()` çağırabiliyor. Kapanışta çökme beklenmiyor, olası sonuç tek bir `encode_failed` log satırı. Rapor normal akıştaki asıl etkiyi atlamış: PTS geri gidebiliyor ve keyframe bayrağı yanlış kareye düşebiliyor. |
| M03 | Decoder kapanışında süre ve sahiplik sözleşmesi yok | **Doğru** | Yeni decode thread'i eskisini süresiz bekliyor ve bunu log'a yazmıyor. Rapor şunu atlamış: bir sonraki nesil eski *çıkış* thread'ini hiç beklemiyor. |
| M04 | Kalem zaman aralıkları host'ta uygulanmıyor | **Doğru, bilinen ve bilerek ertelenmiş** | PLAN Aşama 5'te kullanıcı kararıyla (2026-09-30) "en sona" bırakılmıştı. Rapor şunu atlamış: ağ takılınca host, gecikmiş KEY UP gelene kadar tuşu otomatik tekrarlamaya devam edebiliyor (en çok ~1,5 sn). |
| M05 | Gereğinden geniş ağ ve dosya kapsamı | **Doğru** | "Yalnız USB" modu yok. Dosya paylaşımı tüm `/sdcard`'ı açıyor. WebDAV sunucusu yalnız USB oturumunda değil, uygulama ön plandayken çalışıyor. |
| M06 | Özel API ve başsız kurtarma ürün sınırı olarak yönetilmeli | **Doğru** | Login item'da "ilk çalıştırma" bayrağı kayıt denenmeden önce yazılıyor. Kayıt bir kez başarısız olursa bir daha denenmiyor. |
| M07 | Testler güçlü ama CI ve uzun kullanım kanıtı yok | **Kısmen doğru** | CI yok, `androidTest` yok. Ama pacing izleri ve replay testleri `tools/pacing/` altında zaten var. Host'ta yalnız Core test hedefi var, bu yüzden deterministik yarış testleri için önce test arayüzü (seam) gerekiyor. |
| L01 | README ve build kimliği gerçeği yansıtmıyor | **Doğru** | README "Faz 0" diyor. `versionName` 0.1. İki tarafta da commit ya da build tarihi log'a yazılmıyor. |
| L02 | Deney ayarları ürün yolunu karmaşıklaştırıyor | **Kısmen doğru** | 33 açılış parametresi, 25 `MATEBRIDGE_*` ortam değişkeni ve 4 CLI modu var. Bunların 15'i emekliye ayrılabilir. Günlük ayar ekranında deney ayarı yok. Ama `MainActivity` exported, yani başka bir uygulama bu parametrelerle açabilir. |
| L03 | Kopya ve OS sorgusu maliyeti | **Kısmen doğru, düşük öncelik** | Kopyalar var, ama ölçülmüş ve küçük: host'ta encode sonrası ~0,3 ms p50, tablette giriş kopyası 0,11 ms. |

**H01 ayrıntısı:**
- Tablet, ilk eşleşme yanıtında yeni anahtarı eskisinin üzerine yazıyor. Eşleşme kodunu onaylayan bir düğme yok, kod yalnız ekranda gösteriliyor.
- Wi-Fi'de tablet, bulduğu **herhangi** bir `_matebridge._tcp` servisine kendiliğinden bağlanıyor ve aradaki bir seçim ekranı yok.
- Sahte bir host bu yolla input, iki yönlü pano ve dosya paylaşım token'ını alabiliyor. Bunun için Mac'in host_id'sini taklit etmesi gerekmiyor; aynı host_id'yi kullanırsa kayıtlı anahtarı da bozuyor.
- Rapor iki yolu atlamış:
  - Tablette yalnız INTERNET izni olan bir uygulama `127.0.0.1:47001`'i dinlerse aynı şekilde token'ı ve tüm `/sdcard` erişimini alabiliyor.
  - USB'ye geçiş, doğrulanmamış bir ACCEPTED ile terfi ediyor.
- Düzeltme için protokol baytları değişmiyor; gereken tabletteki durum ve arayüz değişikliği.
- Bu davranış PROTOCOL §9 ve T-044'te bilerek seçilmişti. Bu yüzden önce bir karar (0018) gerekiyor.

**Raporun Kritik/Yüksek/Orta/Düşük derecelendirmesi** genelde yerinde. Doğrulamada ayrılan noktalar:
- H01'in etkisi raporun dediğinden büyük.
- M02 Orta değil Düşük–Orta.
- L03 Düşük ve "önce ölç" kalmalı.

## Raporun atladığı, doğrulamada bulunanlar

| Konu | Ciddiyet | Kart |
|---|---|---|
| Tabletin keşfettiği her host'a kendiliğinden bağlanması, seçim ekranı olmaması | Yüksek (H01 ile) | T-150, T-151 |
| `127.0.0.1:47001`'i dinleyen yerel uygulamanın WebDAV token'ını alabilmesi | Yüksek (H01 ile) | T-150, T-153 |
| USB'ye geçişin doğrulanmamış ACCEPTED ile terfi etmesi | Düşük (DoS) | T-150 |
| Mac'in, PAIRED bağlantıyı anahtar kanıtından önce etkinleştirmesi. Sanal ekran oluşturuluyor, ekranlar uyanıyor, uyku engelleniyor. | Düşük–Orta (yalnız kaynak/DoS) | T-152 |
| `allowBackup=false`, targetSdk 31'de cihazdan cihaza aktarımı kapatmıyor | Düşük | T-154 |
| Aynı host_id'li sahte host sonrası sonsuz PROTOCOL_ERROR döngüsü | Orta | T-156 |
| Yakalama/encoder hatasında sanal ekranın anında kalkması | Orta | T-200 (ölçüme bağlı) |
| Host'ta kuyruk düşüşlerinin her seferinde sınırsız IDR zorlaması (Wi-Fi'de kendini besleyebilir) | Orta | T-176 |
| Ağ takılınca tuşun otomatik tekrarının sürmesi | Orta | T-163 |
| `VideoStats` kare haritalarının hiç temizlenmemesi; yeniden bağlanmalardan sonra örnekler düşebilir | Düşük–Orta | T-168 |
| `CMBlockBuffer`'ın bitişik olduğu varsayılarak okunması | Düşük | T-162 |
| Ses writer nesillerinin üst üste binebilmesi | Düşük | izleniyor (T-164, T-194) |
| Ses mesajlarının (AUDIO_CONFIG/AUDIO_FRAME) oturum kabulünden önce de işlenmesi; sahte host ses çalabiliyor | Düşük (H01 ile) | T-150 |
| `gen.py`'nin `--check` olmadan her çağrıda fixture'ları yeniden yazması | Düşük | T-149 |

## Raporda düzeltilmesi gerekenler

- **H03:** video tarafında kernel'deki gönderilmemiş bayt zaten sınırlı.
- **Palm rejection (PK5):** önerilen "kalem yakındayken parmak kapalı" politikası zaten varsayılan (karar 0006).
- **Yerel kalem izi (A5):** zaten var (T-056), kullanıcı isteğiyle kapalı (T-064).
- **Klavye testleri (PK7, X10):** büyük kısmı 2026-09-30'da cihazda yapıldı.
- **Mod değişince ekranın yeniden yaratılması (PF5):** yalnız yenileme hızı değişince oluyor; karar 0016 bunu zaten ele alıyor.
- **"Replay materyali yok" (M07):** `tools/pacing/` var.
- **Optik ölçüm önerisi:** raporun önerdiği p95 < 45 ms hedefi, mevcut yazılım aşamalarının toplamına (USB/120 Hz'de p50 ~45–55 ms tahmini) göre fazla sıkı. Hedef, optik taban ölçümünden (T-174) sonra konmalı.

`verify-*` raporlarındaki dört "düzeltme" aslında bizim çevirimizden kaynaklandı, raporun hatası değil: LM4 "daha eski değil", IN10 "kontrol aralığı değil", V8 "async değil", PF1 "yakalanan değil, alınan" (`coverage-audit.md` §1.2). `claims.md` sonradan düzeltildi.

## Plan

PLAN.md'ye **Aşama 6 — Güvenilirlik ve ölçüm** eklendi. Kartlar T-145…T-203 ve yeniden kapsamlanan T-127, raporun önerdiği sırayla dizildi: güvenli taban → güven sınırı → video sağlığı → sanal ekran → ölçüm → Wi-Fi → kalem → profiller → kapsam ve kurulum → dayanıklılık. Ölçüme bağlı kartlar en sonda ve her biri hangi ölçümü beklediğini söylüyor. Sıralama, aynı dosyaya dokunan kartlar ve izlenebilirlik tablosu için bkz. `manifest.md` §2 ve §6.

Karar taslakları 0018–0028 `docs/decisions/` altında. Hepsi **önerildi** durumunda, kullanıcı onayı bekliyor. Kart çıkarılmayan öneriler ve gerekçeleri `manifest.md` §4'te.

Hiçbir kart protokol baytlarını koşulsuz değiştirmiyor. Yalnız iki kart, ilgili karar o seçeneği seçerse wire değişikliğine dönüşür: T-172 (karar 0021 B seçeneği) ve T-180 (tilt işareti yanlış çıkarsa).

## Dosyalar

| Dosya | İçerik |
|---|---|
| `claims.md` | Raporun numaralı madde listesi (İngilizce) ve ek O1–O18 |
| `verify-A-security.md`, `verify-A2-adversarial.md` | Güvenlik, eşleşme, ağ ve dosya kapsamı; karşı-doğrulama |
| `verify-B-client-video.md` | Tablette video sağlığı, nesiller, decoder kapanışı |
| `verify-C-host-video.md` | Mac'te yakalama, encoder, gönderim |
| `verify-D-display.md` | Sanal ekran ömrü, özel API, kurtarma, uyku |
| `verify-E-measurement.md` | Gecikme ölçümü, istatistikler, yenileme hızı |
| `verify-F-network.md` | Wi-Fi, bit hızı, kontrol kanalı kuyrukları |
| `verify-G-input.md` | Kalem, palm, klavye/fare, input tazeliği |
| `verify-H-hygiene.md` | Test/CI, dokümanlar, build kimliği, deney ayarları envanteri |
| `coverage-audit.md` | Kapsam denetimi, çelişkiler ve çözümleri |
| `manifest.md` | Kart ve karar listesi, sıralama, izlenebilirlik, açık sorular |
