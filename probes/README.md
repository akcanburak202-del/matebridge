# Probes

Aşama 0 deneyleri. Her probe bağımsız, küçük ve tek bir soruyu cevaplar. Ürün kodu değildir. Sonuçları `docs/NOTES.md`'ye yazılır. Kanıtlanan parçalar daha sonra `host-mac/` veya `client-android/` içine taşınır.

| Probe | Soru | Kart |
|---|---|---|
| `input-probe/` (Android) | Kalem, klavye ve trackpad Android'e ne veriyor? | T-003 |
| `vdisplay-probe/` (Swift) | macOS 27'de 2800×1840 HiDPI sanal ekran oluşturup yakalayabiliyor muyuz? | T-004 |
| `pen-sink-probe/` (Swift) | Sentetik basınç/eğim olaylarını macOS uygulamaları kalem olarak görüyor mu? | T-005 |
| `aaudio-probe/` (Android, NDK) | Tablette AAudio MMAP var mı, çıkış gecikmesi AudioTrack'e göre ne kadar düşük? | T-099 |
| `hdr-probe/` (Swift + Android) | Sanal ekran HDR (EDR) bildirebilir mi, SCK/VT 10-bit PQ hattı ve tablette HDR10 gösterim çalışıyor mu? | T-226 |
| `color-range-probe/` (Swift) | HEVC bit akışında siyah gerçekten Y=0 mı, SPS VUI `video_full_range_flag` ve renk açıklaması ne? | T-230 |
| `decoder-concurrency-probe/` (Swift + Android) | Tabletin HEVC çözücüsü eş zamanlı oturumlarla (1/2/3, tam/yarım kare) toplam hızı artırıyor mu? 10-bit (SDR/HDR PQ) ve 60–150 Mbps'te kapasite/gecikme nasıl? | T-248, T-249 |
| `yuv444-probe/` (Swift; tablet yarısı `android/` T-254) | 4:4:4 görüntüyü AVC444v2 düzeniyle iki 4:2:0 HEVC akışında taşımak Mac bütçesine sığar mı? Metal paketleyici süresi, iki VT oturumu, yardımcı bit maliyeti, geri kurulan renk kalitesi, etiket yeniden yazımında bit-tamlık; tablet için v2 çift klipler. | T-255 |
| `cursor-probe/` (Swift) | Yerel imleç fikri: başka uygulamaların imleç şekli, hotspot, gizli durumu ve konumu herkese açık API ile okunabiliyor mu, yoklama maliyeti ne? | T-271 |
| `usb-tether-probe/` (Android dex + sh) | USB tethering (NCM) adb kabuğuyla başlatılıp uygulama Mac'e adb tünelsiz ulaşabilir mi? (Sonuç: hayır, MRDI-W09) | T-273 |
