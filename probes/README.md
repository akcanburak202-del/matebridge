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
| `decoder-concurrency-probe/` (Swift + Android) | Tabletin HEVC çözücüsü eş zamanlı oturumlarla (1/2/3, tam/yarım kare) toplam hızı artırıyor mu? | T-248 |
