# MateBridge: üç iyileştirme fikri (orkestratöre)

- **Tarih:** 2026-10-06
- **Kaynak:** ayrı bir Claude oturumunda salt okunur inceleme (`main` @ `babccf6`). Repoda hiçbir şey değiştirilmedi.
- **Kullanıcının ilgilendiği maddeler:** 1, 2 ve 3.
- **Bu belge karar değil, öneridir.** Kart açmak, öncelik vermek ve protokol değişiklikleri orkestratörün işidir. Kanıt etiketleri:
  - **[repo]:** dosya ya da satır referansı var.
  - **[kaynak]:** web kaynağı.
  - **[doğrulanmadı]:** prob ya da ölçüm gerekiyor.

Bağlam: ChatGPT'nin "DisplayLink benzeri sürücü" önerisi değerlendirildi ve **elendi**. DisplayLink Manager'ın kendisi de macOS'ta ekran kaydı izniyle, yani ekran yakalama yoluyla çalışıyor ([Plugable](https://kb.plugable.com/docking-stations/why-does-macos-say-displaylink-manager-is-capturing-your-screen), [DisplayLink](https://support.displaylink.com/knowledgebase/articles/1950940-macos)). Asıl farkı karşı uçtaki çözme çipi, MatePad'de bunun karşılığı zaten MediaCodec. Bu yüzden sürücü yazmak gecikme kazancı getirmez. Aşağıdaki üç fikir onun yerine önerilenler.

---

## 1. İmleci tablette çizmek (yerel imleç)

**Öneri önceliği: yüksek.** Günlük kullanımda hissedilen gecikmeye en büyük etkiyi yapabilecek fikir.

### Bugün
- İmleç video karesinin içinde geliyor: `host-mac/Sources/MateBridgeHost/Video/ScreenCapture.swift:80` `cfg.showsCursor = true` [repo].
- Trackpad ya da fareyle imleç hareketi, ekrana videonun tam gecikmesiyle geliyor: yakalama, kodlama, aktarım, çözme ve sunum. Kabaca 40–55 ms (`docs/research/2026-10-04-monitor-vs-matebridge.md`) [repo].
- Kalem için yerel iz ve nokta zaten var. Kullanıcı yerel izi Krita'da gereksiz buldu, varsayılanı kapalı (NOTES, T-064) [repo]. Trackpad ve fare imleci için bir karşılığı yok.

### Fikir
- Host videoda imleci çizmez (`showsCursor = false`).
- Host, imlecin **şeklini** (görüntü, hotspot, ölçek, önbellek kimliği) yalnız değiştiğinde, **konumunu** ise her girdi enjeksiyonundan sonra kontrol kanalından gönderir.
- Tablet imleci videonun üstündeki ayrı bir katmanda çizer.
- USB'de RTT ~2 ms (NOTES:126, :146) [repo]. Bu yüzden ilk sürümde tablette tahmin gerekmez: host'un bildirdiği konum yeterince taze. İmlecin gecikmesi kabaca "girdi + ~2 ms + bir vsync" olur.

### Dikkat edilecekler
- **İmleç şekli nereden alınacak?** Başka uygulamaların imlecini (metin I-beam, yeniden boyutlandırma, Krita'nın özel imleçleri) herkese açık API ile güvenilir biçimde okumak gerekiyor. `NSCursor.currentSystem` aday ama başka süreçlerin imlecini doğru verip vermediği bilinmiyor. **İlk adım bir Mac probu olmalı.** [doğrulanmadı]
- **Gizli imleç:** yazarken ya da oyunda imleç gizlenir. Host gizli durumunu da bildirmeli.
- **Oyun modunda** yerel imleç kapalı olmalı (göreli fare, oyunun kendi imleci).
- **Görüntüyle ayrışma:** pencere sürüklerken imleç pencerenin ~40 ms önünde gider. Parsec gibi uygulamalar bunu kabul ediyor. Seçenek: düğme basılıyken (sürükleme) videodaki imlece geri dönmek.
- **HiDPI:** 1400×920 mantıksal ↔ 2800×1840 piksel ölçeği, imleç görüntüsünün 2x hali.
- **Protokol değişikliği:** yeni mesajlar (ör. `CURSOR_SHAPE`, `CURSOR_STATE`), capability biti, fixture'lar ve Codex `--high` incelemesi. Bu kısım orkestratörde.
- Girdi durumu kurallarına dokunmaz: yalnız görüntüleme, enjeksiyon aynı kalır.

### Önerilen sıra
1. **Mac probu:** başka bir uygulamanın imleç şekli ve gizli durumu herkese açık API ile okunabiliyor mu? Şekil değişince bildirim ya da yoklama maliyeti ne?
2. **Ölçüm:** imleç hareketinden ekrana bugünkü gecikme (mevcut ölçüm yöntemleriyle).
3. Prob olumluysa karar kaydı, sonra protokol ve iki taraf için kartlar.

---

## 2. USB aktarımını `adb reverse` yerine doğrudan bir yola taşımak

**Öneri önceliği: orta.** Önce ölçüm gerekiyor, ucuz bir başlangıç.

### Bugün nasıl çalışıyor
`adb reverse` bir **tünel**. Tablet uygulamasının `127.0.0.1:port`'a açtığı TCP bağlantısı şu yoldan geçiyor:

```
tablet uygulaması → (yerel soket) → adbd [tablet, kullanıcı alanı]
  → adb protokolü paketleri, USB bulk → adb sunucusu [Mac, kullanıcı alanı]
  → (yerel TCP) → MateBridge host
```

Her bayt iki ara süreçten (adbd ve adb sunucusu) ve adb'nin kendi paketlemesinden geçiyor. Repodaki bulgular [repo]:
- **Gecikme payı:** kaba bütçede USB/adb ~4–6 ms (NOTES:402). Ayrı olarak ölçülmedi.
- **Paketleme:** tablette varış aralıkları dönem dönem 40, 0, 40, 0 ms oluyor, yani iki kare birlikte geliyor. Şüphe: adbd yerel soketinde Nagle ve gecikmeli ACK (NOTES:408, T-074).
- **CPU:** tablette `adbd` ~%12 (NOTES:1064).
- **Kararlılık:**
  - adb sunucusu mDNS köprüsünde çöküyor, çökünce tüneller kayboluyor (NOTES:140).
  - Kablo çekilince tüneller gidiyor, `usb-mode.sh` gerekiyor (NOTES:191).
  - Tabletin geliştirici modu ve USB hata ayıklaması açık olmalı.

### Alternatifler
- **(a) USB ağı (USB tethering, NCM/RNDIS):** tablet USB üzerinden gerçek bir ağ arayüzü açar, Mac ile tablet doğrudan IP üzerinden konuşur. Ara süreç yok, trafiği iki taraftaki çekirdek taşır. Bugünkü Wi-Fi kodu (BSD soketi, T-091) neredeyse aynen kullanılır.
  - **Bilinmeyenler** [doğrulanmadı]: Huawei/HarmonyOS 4.3 NCM mi RNDIS mi sunuyor? macOS 27 bunu sürücüsüz tanıyor mu?
  - **Riskler:** tethering, Mac'in internet trafiğini tablete yönlendirebilir (ağ hizmet sırası). Tethering'i açmak sistem ayarı, uygulama açamaz. Otomatik bağlanma zayıflar.
- **(b) Android Open Accessory (AOA):** Mac, USB host olarak tableti "aksesuar" moduna geçirir. Uygulama `UsbAccessory` API'siyle doğrudan USB bulk uçlarını okur ve yazar.
  - **Artılar:** adb, geliştirici modu ve USB hata ayıklaması gerekmez. Ara süreç yok.
  - **Maliyet:** Mac tarafında IOKit USB kodu (yeni bağımlılık değil, sistem çerçevesi). TCP olmadığı için kontrol ve video için çerçeveleme ve akış kontrolü yeniden düşünülmeli. Bu büyük bir iş.
  - **Bilinmeyen** [doğrulanmadı]: HarmonyOS 4.3 AOA'yı destekliyor mu?

### Beklenti (abartmamak için)
- Hat USB 2.0, yani ~35 MB/s ≈ 280 Mbps (`docs/research/2026-10-04-hdr-feasibility.md:193`) [repo]. Bu sınır yol değişince de aynı kalır. Büyük bir karenin kablodan geçme süresi değişmez.
- Kazanç: ara süreçlerin eklediği gecikme, 40/0 ms öbeklenmesi, adbd CPU'su ve adb kararsızlıkları. Yani gecikmeden çok **düzenlilik ve sağlamlık**.

### Ön adım: USB 3 kablo (kod yok, en ucuz)
- Bugün tablet 480 Mbit/s'ta bağlı (NOTES:1059, "USB 3 kablo denemesi" açık madde) [repo]. Büyük olasılıkla kablo USB 2.0. Tabletin USB 3 desteği [doğrulanmadı].
- Her karenin tamamı gelmeden çözme başlamadığı için kablo hızı doğrudan gecikmeye ekleniyor. USB 2.0'da (~35 MB/s):
  - normal kare (~125 KB) ≈ 3,6 ms;
  - keyframe (~432 KB) ≈ 12 ms;
  - oyunda sahne değişimi (300–400 KB) ≈ 9–11 ms (`docs/research/2026-10-04-smoothness.md:48`) [repo].
- USB 3'te (adb dahil pratikte birkaç yüz MB/s) bunlar ~1 ms ve ~1–4 ms'ye iner [tahmin]. Tam renk (yardımcı akış +%30–45 bit), yüksek bit hızı ve madde 3'teki kayıpsız yamalar daha çok kazanır.
- Değiştirmedikleri: 40/0 ms öbeklenmesi, adbd CPU'su ve adb kararsızlıkları. Bunlar tünelden kaynaklanıyor, kablodan değil.
- Doğrulama: USB 3 (5 Gbit/s+) veri kablosuyla tak, `system_profiler SPUSBHostDataType` tablet satırında `Link Speed: 5 Gb/s` görünmeli. Sonra aşağıdaki ölçümü iki kabloyla karşılaştır.

### Önerilen sıra
1. **Ölçüm, kod değişikliği yok:** aynı oturumda host gönderim zamanı → tablet `recv` zamanı (saat farkı düzeltilmiş). Kare boyutuna göre adb tünelinin payını ve 40/0 öbeklenmesinin hâlâ sürüp sürmediğini ayır (T-074 sonrası).
2. **Tablet probu:** USB tethering açılınca Mac'te hangi arayüz çıkıyor (NCM/RNDIS)? Tablete doğrudan TCP ile bağlanılabiliyor mu? Aynı ölçüm tekrarlanır.
3. Kazanç anlamlıysa (a) için karar kaydı. (b) yalnız adb bağımlılığından kurtulmak ayrı bir hedef olursa düşünülür.

---

## 3. Durağan ekranda kayıpsız yamalar

**Öneri önceliği: koşullu.** Yalnız 0034 (Tam renk) görsel değerlendirmesinden sonra yazıda hâlâ sıkıştırma izi görülürse.

### Bugün
- HEVC, 4:4:4 paketlenmiş olsa bile kayıplı. 0034'e göre RGB PSNR 42,7 dB (`docs/decisions/0034-full-chroma-packed-444.md`) [repo].
- T-253 "netleştirme trenleri" ekran durunca kaliteyi artırıyor. Ama kayıpsız değil.
- Durağan ekranda kare gitmiyor (0034 karar §4) [repo].
- ScreenCaptureKit her karede değişen bölgeleri bildiriyor (`SCStreamFrameInfo.dirtyRects`) [kaynak: Apple SDK]. Host bu bilgiyi kullanmıyor; `ScreenCapture.swift` yalnız `displayTime` ve durum okuyor [repo].

### Fikir
- Ekran N ms durgun kalınca host, son kayıpsız durumdan beri değişen bölgeleri (`dirtyRects` birikimi) kaynak pikselden **kayıpsız** sıkıştırır ve yama olarak gönderir. Mac'te Apple Compression (zlib/deflate), tablette `java.util.zip.Inflater`. **Yeni bağımlılık yok.**
- Tablet yamaları GL birleştirme yolunda (tam renk için zaten var) video karesinin üstüne çizer.
- Yeni bir video karesi o bölgeye dokununca yama geçersiz olur.

### Dikkat edilecekler
- **Tutarlılık en büyük risk:** yeni karenin değiştirdiği bölgede eski yama kalırsa yanlış içerik görünür. Geçersiz kılma `dirtyRects` ile ve kare sırasına bağlı yapılmalı.
- **Renk uyumu:** yama sRGB RGB, video YUV → RGB. Ufak bir dönüşüm farkı yama sınırlarında görünür. Daha önce etiket uyumsuzluğundan +8 seviye fark yaşandı (NOTES:799) [repo].
- **Bant:** tam ekran yazı kayıpsız sıkıştırılınca megabaytlar mertebesinde [doğrulanmadı]. Durgun anda bir kez gittiği için USB'de sorun değil. Wi-Fi'de yavaş gelebilir.
- **Protokol değişikliği** (yama mesajı, capability), fixture'lar, Codex.

### Önerilen sıra
1. 0034 görsel kararını bekle.
2. Hâlâ iz varsa **çevrimdışı prob, protokol değişikliği yok:** tipik ekranlardan (kod editörü, Finder, tarayıcı) bir kare al. Çözülmüş HEVC (normal, 0033, 0034) ile kaynağı karşılaştır. Kayıpsız yamanın boyutunu ölç. Kazanç ve bant tablosu çıkar.
3. Tablo ikna ediciyse karar kaydı.

---

## Değerlendirilip önerilmeyenler (yeniden açmaya gerek yok)
- **DisplayLink benzeri sürücü:** yukarıdaki bağlam. Kazanç yok.
- **Fiziksel ekran ya da HDMI dummy yakalama yedeği:** dummy takılı değil (NOTES:1214). Dummy'ler 2800×1840 sunmuyor. Acil durum yolu zaten Parsec ve HDMI kablo (0020).
- **Slice ya da yarım kare kodlama ve çözme, izlerken 120 Hz, kare interpolasyonu:** repoda ölçülüp kapandı (`docs/research/2026-10-04-smoothness.md`, NOTES T-048).
- **Sıkıştırmasız aktarım:** 2800×1840 @60 ≈ 7,4 Gbit/s, USB 2.0'a sığmaz.

---

## Orkestratör değerlendirmesi (2026-10-06)

- **1. Yerel imleç — en değerli.** Trackpad/fare ve kalem hover'ında imleç bugün video gecikmesiyle (~40–55 ms) geliyor; yerel katmanla USB'de ~1 vsync + birkaç ms, Wi-Fi'da ~RTT (~15 ms). Asıl bilinmeyen gerçekten imleç şeklinin herkese açık API ile okunabilmesi (`NSCursor.currentSystem`; aksi hâlde özel API, ki AGENTS.md'ye göre ayrı karar ister). Önce küçük Mac probu (GUI açmadan; başka uygulamaların imleçleri, gizli durum, değişim maliyeti). Wi-Fi dosyaları (0035) bittikten sonra ya da paralel prob olarak.
- **2. USB yolu.**
  - **40/0 ms öbeklenmesi zaten giderildi:** T-074 (`TCP_QUICKACK`) A/B ile kesin çözdü (NOTES 2026-10-01 ~13:20). Belgedeki bu gerekçe güncel değil.
  - **USB 3 kablo denemesi en ucuz adım** (kod yok, kullanıcı kablo takar, `system_profiler SPUSBHostDataType` hızı okunur); büyük kare ve keyframe aktarımı, Tam renk, dosya aktarımı kazanır.
  - **USB tethering:** Huawei büyük olasılıkla RNDIS sunar; macOS RNDIS'i yerleşik desteklemez (yalnız CDC-ECM/NCM) [doğrulanmadı] → engel olabilir. Ayrıca Mac'in internet trafiğini tablete kaydırma riski. Prob ancak kablo testi ve adb payı ölçümünden sonra.
  - **AOA:** büyük iş; yalnız "adb'siz kurulum" ayrı bir hedef olursa.
- **3. Kayıpsız yamalar — park.** Koşulu oluşmadı: kullanıcı Keskin kenarları yeterli buldu, Tam renk yalnız hafif iyileşme (NOTES 2026-10-06 ~10:40–11:00), T-253 netleştirmeden sonra "yazılar net". Kullanıcı yazıda iz şikâyet ederse yeniden açılır.
