---
id: T-262
title: Host — shrink the full-chroma auxiliary stream (aux bytes are 1.25–1.5× main instead of ~0.4×)
status: review
phase: 6
owner: mac-host-dev
depends_on: [T-258]
decisions: [0034]
files:
  - host-mac/Sources/MateBridgeCore/Video/
  - host-mac/Sources/MateBridgeHost/Video/
  - host-mac/Tests/
  - probes/yuv444-probe/
  - docs/LOGGING.md
  - backlog/tasks/T-262-host-aux-size.md
---

## Amaç

İlk cihaz testinde host `ev=chroma_stats aux_main_bytes` 1,23–1,50 (NOTES 2026-10-06 ~00:35); tasarım/T-255 M3 ~0,3–0,45 bekliyordu. Büyük yardımcı kare Wi-Fi'da geç geliyor (titreme nedeninin bir parçası, T-261 istemci tarafını çözüyor) ve toplam bant ~2,2–2,5×. Yardımcıyı küçült, ama kaliteyi koru.

## Bağlam

- Önce **neden**: yardımcı oturumun `AverageBitRate`/`DataRateLimits`'i (ana hedefin %50'si) etkili mi (`PackedAuxEncoder.swift` ~86, ~153; T-258 Codex düzeltmesiyle sıralı uygulanıyor)? Yardımcı içerik (Cb/Cr örneklerinin luma gibi paketlenmesi) kodlayıcı için "gürültülü" mü; T-253 netleştirme trenleri iki akışta da çalışırken yardımcı payı mı şişiriyor? `aux_main_bytes`'ı hareketli / durağan / netleştirme için ayrı ölç (log alanı ekle).
- Seçenekler (ölçerek seç, `probes/yuv444-probe` encode-bench / quality ile Mac'te, pencere açmadan): yardımcıya daha düşük kalite/ hedef (ör. ana %25–35), yardımcıda netleştirme trenini kısıtlama ya da kapama, yardımcının IDR aralığı, `MaxFrameDelayCount`/`MaxAllowedFrameQP` gibi VT ayarları. Kalite ölçütü: T-255 M3 RGB PSNR ve renkli yazı kırpıntıları (tam renk 4:2:0'dan belirgin iyi kalmalı; hedef ≥ 41 dB yapay sahnede).
- Tel biçimi ve istemci değişmez.

## Kabul kriterleri

- [x] Ölçüm tablosu (önce/sonra: aux/main bayt oranı hareketli/durağan, PSNR) Handoff'ta; seçilen ayarın gerekçesi.
- [x] `./scripts/check.sh` geçer; birim testleri değişen politika için.
- [x] Handoff: cihaz doğrulama adımları (`aux_main_bytes`, `aux_paired_pct` istemcide).

## Plan

1. Önce nedeni ölç: `host-0023.log` `chroma_stats` pencerelerini `net ev=stats` ile hizala (oran hangi içerikte yüksek?). Sonra `probes/yuv444-probe quality` ile (host'un seçimi `--main-chroma pick`, ana 30 Mbps) yardımcı hedefi, `MinAllowedFrameQP`, `Quality` ve içerik gürültüsünü tara; `encode-bench` ile kodlama süresine etkisini kontrol et.
2. Seçilen ayarı saf bir Core politikasına koy (`AuxBitratePolicy`), `PackedAuxEncoder` onu kullansın, birim testi.
3. `ev=chroma_stats`'a `main_kbps`, `aux_kbps` ve kare türüne göre (key/refine/delta) oran ekle; test, `docs/LOGGING.md`.

## Handoff

- **Commit:** dal `task/T-262-aux-size` (main 3505d1f üzerine, tek commit "T-262: ..."; SHA için dalın ucu). `./scripts/check.sh`: ALL OK.
- **Dokunulan dosyalar:** Core `Video/AuxBitratePolicy.swift` (yeni), `Video/PackedChromaFlow.swift` (`PackedFrameKind`, `PackedChromaStatsWindow` yeni alanlar); Host `Video/PackedAuxEncoder.swift` (politikayı kullanır), `Video/HEVCEncoder.swift` (istatistiğe kare türü); test `PackedChromaTests` (güncel 1 + yeni 2 test); `docs/LOGGING.md`; probe `yuv444-probe` (`Quality.swift`, `Sequence.swift`, `VTStream.swift`, README: yeni deney bayrakları). Tel biçimi ve istemci değişmedi.

### Bulgu 1: 1,2-1,5 oranı küçük-sayı etkisi, bant sorunu değil

`host-0023.log` (gen=4, Wi-Fi, 30 Mbps ana hedef) `chroma_stats` pencereleri, her birine karşılık gelen `net ev=stats` ortalamasıyla (10 sn pencere; kbps = ana + yardımcı birlikte gönderilen):

| pencere | kare | aux/main | gönderilen kbps | içerik |
|---|---|---|---|---|
| 50237 | 160 | 0,24 | 714 | hareketli |
| 50247 | 335 | 0,28 | 2752 | hareketli (1 sn'de 13-47 Mbps tepe) |
| 50258 | 315 | 0,14 | 6216 | hareketli |
| 50268 | 253 | 1,14 | 468 | durağan + refine trenleri |
| 50278 | 157 | 1,25 | 245 | durağan |
| 50288 | 154 | 1,50 | 217 | durağan |
| 50299 | 131 | 1,49 | 178 | durağan |
| 50310 | 127 | 1,49 | 167 | durağan |
| 50321 | 148 | 1,50 | 193 | durağan |
| 50332 | 219 | 1,23 | 332 | durağan |
| 50343 | 184 | 1,26 | 268 | durağan |

Yüksek oran (1,14-1,5) yalnız toplam 170-470 kbps olan durağan pencerelerde. Orada ana ve yardımcı delta karesi birkaç yüz bayttır (kare başı yükü baskın; probe "typing" fazı: 0,4 kB ana, 0,4 kB yardımcı, oran 0,9-1,0). Hareketli pencerelerde oran 0,14-0,28, tasarım değerinde. NOTES 2026-10-06 ~00:35'teki "toplam bant ~2,2-2,5x" durağan pencerelerin oranından çıkarılmış; bayt ağırlıklı toplam hareketli içerikte ~1,15-1,3x. Geç gelen yardımcı karenin (`aux_late`) sebebi bayt değil sıralama (ana ardından ~6 ms kodlama, tek motor); onu T-261 çözüyor. Durağan karelerde yardımcı boyutu küçültmenin anlamı yok: probe'da `MinAllowedFrameQP` 28-36 still faz yardımcı karesini 1,5 kB'tan 0,8-0,4 kB'a indirir ama toplam hız zaten 0,4-0,8 Mbps; bedeli 1-4 dB RGB kalite.

### Bulgu 2: yardımcı hedef yalnız bağlayıcı olduğunda etkili; orada %50 cömert

Probe `quality` (2800x1840, ana hedef 30 Mbps, ana kroma `pick` = ürün, 600 kare, 4 faz): VideoToolbox yardımcıda hedefin altında kaldıkça (durağan, yazı, kaydırma) hedef boyutu değiştirmiyor; yalnız ağır/gürültülü harekette (video fazı) hedefe oturuyor. %50'de gürültülü videoda yardımcı kendi hedefini bile aşıyor (17,5 Mbps; `box` ana kromada ana 12,8 Mbps iken oran 1,37). Önce/sonra (`--grain 14`, `pick`; aux kB = kare başı kilobayt, oran = aux/main; PSNR dB, 4 faz örnek karesinin ortalaması, kaynak RGB'ye göre; kenar = renk kenarı pikselleri):

| yardımcı hedef | still aux kB (oran) | scroll aux kB (oran) | video aux Mbps (oran) | IDR aux kB | RGB dB | kenar Cb/Cr dB |
|---|---|---|---|---|---|---|
| %50 (önce) | 2,2 (0,43) | 2,3 (0,31) | 17,5 (0,58) | 66 | 39,62 | 36,4 / 35,4 |
| %30 | 1,5 (0,30) | 2,1 (0,28) | 10,5 (0,35) | 50 | 38,55 | 34,5 / 33,5 |
| **%25 (seçilen)** | 1,6 (0,32) | 2,1 (0,28) | 8,8 (0,29) | 45 | 38,48 | 34,3 / 33,2 |
| %20 | 1,5 (0,30) | 2,2 (0,29) | 7,1 (0,24) | 35 | 38,17 | 33,9 / 32,8 |
| %12 | 1,7 (0,32) | 2,2 (0,29) | 4,2 (0,14) | 22 | 38,03 | 33,8 / 32,8 |
| %6 | 1,9 (0,36) | 2,2 (0,29) | 2,1 (0,07) | 9 | 37,75 | 33,1 / 32,0 |

Taban (yalnız ana 4:2:0 `box`, aynı sahne): RGB 35,6 dB, kenar Cb/Cr 27,7 / 24,9 dB. %25 hâlâ 4:2:0'dan RGB +2,9 dB, renk kenarında +6,6 / +8,3 dB iyi (önceki %50 için: +4,0 / +8,7 / +10,5).
Ek koşullar: `--grain 40` (çok ağır video, ana ~36 Mbps): %50 aux 17,8 Mbps (0,49) RGB 37,39; %30 10,7 (0,30) RGB 36,40; %25 8,9 (0,25) RGB 36,42. Ana 8 Mbps, grain 14 (iki oturum da bağlayıcı): %50 video aux 4,7 Mbps (0,71) RGB 36,68; %30 2,8 (0,42) 36,50; %25 2,3 (0,35) 36,49.
Seçim gerekçesi: %30 ile %25 arasında kalite farkı ölçüm gürültüsü içinde (grain 40'ta aynı, grain 14'te RGB 0,07 dB); %12'ye inmek ek bant kazandırır ama kenar kalitesi ve gürültülü videoda renk düşer; %25 kartın istediği %25-35 aralığının dibinde, ağır harekette toplam bant ~1,5x yerine ~1,3x. Yardımcı IDR 66 -> 45 kB (ana IDR 209 kB).
Kodlama süresi etkilenmedi (paced `encode-bench`, 60 fps, scroll/video, %50 ve %25: aux enc p50 11,1-11,4 ms, ana 5,9-6,2 ms).
Elenenler: `MinAllowedFrameQP` (yalnız durağan/küçük karelerde etkili, kalite kaybı büyük, bant kazancı yok), yardımcıya `Quality` 0,5 (yardımcı büyür: video 21,8 Mbps), yardımcıda ayrı burst katsayısı / IDR aralığı / `MaxFrameDelayCount` ölçülmedi (sorun ortalama bayt değil sıralama; yardımcı IDR zaten ana IDR'ın %22-32'si).

### Yapılanlar

1. `AuxBitratePolicy`: yardımcı `AverageBitRate`/`DataRateLimits` = ana hedefin %25'i, en az 1 Mbps (önce %50). Canlı bit hızı değişimi aynı politikayı izler (`setBitrate`).
2. `ev=chroma_stats` (packed444) yeni alanlar: `main_kbps`, `aux_kbps` (pencere ortalaması; meşgul/durağan ayrımı), `aux_main_key`, `aux_main_refine`, `aux_main_delta` (kare türüne göre oran). `aux_main_bytes` aynen; yeni alanlar sona eklendi.
3. Probe: `quality`'ye `--by-phase`, `--aux-min-qp/-max-qp/-quality/-burst`.

### Uyarılar ve doğrulanmayanlar

- **Benchmark koşulu:** canlı MateBridge host uygulaması bu Mac'te açıktı (akış yok, CPU ~%8) ve başka işler vardı (load average 1,8-3,1). Bayt/PSNR sayıları yük-bağımsızdır; `encode-bench` süreleri (aux enc ~11 ms, hostta 6,3 ms) paylaşılan motorda ölçüldü, mutlak ms'e değil %50 ile %25 farkına bakın.
- Sentetik sahne gerçek içerik değil. T-255'in 41 dB RGB hedefi ana Y PSNR'ı ~44 dB iken RGB'yi ~39-40 dB ile sınırlıyor (sıkıştırma öncesi paketli RGB 57,9 dB); hedef bu koşullarda %50'de bile yok, karşılaştırma 4:2:0'a göre yapıldı.
- **Cihazda doğrulanacak:** hareketli içerikte (video, kaydırma, ağır albüm görseli) `ev=chroma_stats` `aux_main_delta` ~0,25-0,35 ve toplam kbps ~1,3x ana; durağan pencerede `main_kbps`/`aux_kbps` birkaç yüz kbps (oran ~1-1,5 normaldir, endişe değil); renkli yazı kenarları ve (özellikle gürültülü) video/fotoğraf %50'ye göre gözle fark edilir kötüleşmemiş olmalı. `aux_paired_pct`/`aux_late` bu görevle değişmez (T-261 ve gönderim sırası).

## Open questions

- Yardımcı hedef için çalışma zamanı ayarı (`MATEBRIDGE_AUX_PERCENT` gibi) eklenmedi: `docs/KNOBS.md` kartın `files:` listesinde değil. Cihaz A/B'si gerekirse orkestratör ister (Core'da tek sabit).
