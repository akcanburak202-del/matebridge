---
id: T-113
title: Mac — uygulamadaki kodlama süresi (enc_ms ~9,5 ms) yalıtılmış bench'ten (~6,4 ms) neden uzun? Ölç, nedeni bul
status: review
phase: 5
owner: mac-host-dev
depends_on: []
decisions: []
files:
  - host-mac/Sources/MateBridgeHost/Video/
  - host-mac/Sources/MateBridgeCore/Video/
  - host-mac/Tests/
  - docs/NOTES.md
  - backlog/tasks/T-113-host-encode-time-gap.md
---

## Amaç

Dilimli kodlama araştırması (NOTES 2026-10-02 ~00:50):
- yalıtılmış bench, 2800×1840 HEVC, `fast` profil (speed priority açık, RealTime kapalı): kodlama p50 **6,4 ms**;
- çalışan uygulamanın `ev=latency enc_ms` değeri 60 fps'te 9,4–9,8 ms.

Olası nedenler:
- gerçek ekran içeriği (sentetik metinden farklı);
- aynı anda 2 kare kodlayıcıda (in-flight kuyruğu, `enc_ms` bekleme dahil mi?);
- IOSurface/piksel biçimi dönüşümü;
- güç ve frekans durumu;
- ölçüm noktasının farkı.

~3 ms kazanç olasılığı var.

## Kabul kriterleri

- [x] `enc_ms`'in tam olarak neyi ölçtüğü yazılır: hangi zaman damgasından hangisine, kuyrukta bekleme dahil mi.
- [x] Uygulama **durdurulmuşken** (tek donanım kodlayıcı paylaşılmasın) A/B ölçüm yapılır:
  - mevcut `EncodeBench`/`SharpnessBench` ya da yeni bench seçeneği;
  - gerçekçi içerik (kaydedilmiş SCK kareleri ya da gerçek ekran yakalama);
  - in-flight 1 ve 2;
  - uygulamanın kullandığı piksel biçimi ve özellikler ile bench'inkiler.
- [x] Neden bulunur ve NOTES'a yazılır. Ucuz, güvenli bir düzeltme varsa (örn. ölçüm yanlışsa düzeltme, ya da bir özellik farkı) uygulanır, ayar düğmesiyle (env) karşılaştırılabilir kalır. Büyük değişiklik gerekiyorsa ayrı kart önerilir.
- [x] `./scripts/check.sh` geçiyor.

## Notlar

- Uygulamayı durdurmak oturumu keser. Orkestratör izin verdiğinde yapılır; sonunda uygulama yeniden başlatılır: `open build/MateBridge.app`.

## Plan

1. Ölçüm noktasını koddan çıkar: `enc_ms` = `FrameTrace.encUs` = `submittedUs` (VTCompressionSessionEncodeFrame çağrısından hemen önce) → `encodedUs` (çıkış callback'i). Slot beklemesi (`slot_wait`) ayrı; ama VT içinde önceki karenin bitmesini beklemek (in-flight 2) `enc`'e dahil.
2. Uygulama logundan ön analiz: `enc_ms` kare hızına göre (2/s'de de ~9 ms ise kuyruk değil).
3. Uygulama durdurulmuşken scratchpad'de tek değişkenli A/B probu (swiftc, repo dışı):
   - bench'in `VTCompressionSessionCompleteFrames` çağrısı var/yok;
   - Require vs Enable donanım kodlayıcı;
   - içerik: sentetik vs SCK ile yakalanmış gerçek ekran kareleri (aynı biçim, 2800×1840'a ölçekli);
   - tampon kaynağı: SCK IOSurface vs CVPixelBufferCreate;
   - in-flight 1 vs 2; tempo 2/60/120 fps;
   - uygulamanın tam özellik seti vs bench'inki.
4. Kök neden bulunursa ve ucuz/güvenliyse `HEVCEncoder`'da env düğmesiyle (varsayılan değişikliği ayrıca gerekçeli) düzelt; `EncoderKnobs` (Core) ayrıştırması birim testli. Gerekirse `--encode-bench`'e seçenek ekle.
5. Bulguları NOTES'a (tarihli) yaz, `./scripts/check.sh`, Handoff.

## Handoff

- **Commit:** `2e21833` (uygulama + NOTES). Plan `bcef99a`. Bu Handoff ayrı bir commit'te.
- **Kök neden:**
  - SCK, sRGB 420f tamponlarını `TransferFunction=ITU_R_709_2` ile etiketliyor (artı 709 primaries/matris ve sRGB `CGColorSpace`).
  - Oturum `TransferFunction=IEC_sRGB` istiyor.
  - VideoToolbox bu yüzden her kareyi kodlamadan önce renk dönüşümünden geçiriyor: 2800×1840'ta ~2,4–3 ms. Piksel de değişiyor: Y ortalama +8 seviye, yani tablet görüntüsü biraz açık/soluk.
  - Yalıtılmış bench'ler etiketsiz sentetik kare kullandığı için bunu hiç görmedi.
  - Ayrıntı ve tablolar: NOTES 2026-10-02 ~01:20.
- **`enc_ms` tanımı:** `submittedUs` (VTCompressionSessionEncodeFrame'den hemen önce) → `encodedUs` (callback başı). `hold`/`slot_wait` dahil değil. In-flight 2 etkisiz ölçüldü.
- **Düzeltme:**
  - `HEVCEncoder.encode`, yakalanan tamponun 3 renk etiketini oturumunkilerle değiştiriyor (`retagForSession`, piksel değişmez). Karar mantığı `InputRetag`/`ColorTags` (Core, birim testli).
  - Düğme: `MATEBRIDGE_INPUT_RETAG=0` eski davranış. `ev=encoder_config` satırına `input_retag=0|1` eklendi.
  - Oturum başına ilk retag'de bir kez `ev=input_retag from=… to=…` yazılıyor.
  - `--encode-bench` yeni seçenek alıyor: `--input-tags none|sck`. Bench oturumu artık uygulamanın renk özelliklerini de ayarlıyor. Etiketsiz karede fark yok (ölçüldü).
- **Ölçülen kazanç (RETAG 0 → 1):**

  | Ölçüm | RETAG=0 | RETAG=1 |
  |---|---|---|
  | bench sck paced 60 | 9,3 ms | 6,6 ms |
  | bench paced 120 | 8,7 ms | 6,0 ms |
  | `--dump-video` gerçek SCK | 11,4 ms | 8,4 ms |

  Bitstream VUI değişmedi (primaries=1 transfer=13 matrix=1, STREAM_CONFIG ile eşleşiyor).
- **Beklenen:** cihazda `ev=latency enc_ms` p50 ~9,5 → ~6,5–7 ms; `cap_to_sent` de aynı miktarda düşer.
- **Dokunulan dosyalar:**
  - `host-mac/Sources/MateBridgeCore/Video/InputColorTags.swift` (yeni)
  - `host-mac/Sources/MateBridgeCore/Video/EncoderKnobs.swift`
  - `host-mac/Sources/MateBridgeCore/Video/EncodeBench.swift`
  - `host-mac/Sources/MateBridgeHost/Video/HEVCEncoder.swift`
  - `host-mac/Sources/MateBridgeHost/Video/EncodeBench.swift`
  - `host-mac/Tests/MateBridgeCoreTests/Video/InputColorTagsTests.swift` (yeni)
  - `host-mac/Tests/MateBridgeCoreTests/Video/EncoderKnobsTests.swift`
  - `host-mac/Tests/MateBridgeCoreTests/Video/EncodeBenchTests.swift`
  - `docs/NOTES.md`
  - bu kart
- **Varsayımlar:**
  - SCK tampon etiketlerini teslimden önce koyuyor ve teslimden sonra tampona dokunmuyor, bu yüzden SCK sample kuyruğunda etiketi değiştirmek güvenli. Değer idempotent; yeniden gönderilen `last` aynı nesne.
  - SCK'nin piksel değerleri gerçekten sRGB kodlu (`colorSpaceName = sRGB`), yani sRGB etiketi doğru ve dönüşüm hatalıydı.
- **Test edilmeyenler (cihaz gerekli):**
  - tablette `enc_ms`/`cap_to_sent` düşüşü (`ev=latency`);
  - görüntünün Mac'le renk/parlaklık karşılaştırması: biraz koyulaşması beklenir, doğrusu bu;
  - H.264 yolu (`MATEBRIDGE_CODEC=h264`) aynı oturum etiketlerini kullanıyor ama ayrıca ölçülmedi;
  - Performans/Oyun ölçekli mod (SCK ölçekli çıktı aynı etiketleri koyuyor olmalı).
- **Uygulama:** ölçüm için durduruldu, sonunda `open build/MateBridge.app` ile yeniden başlatıldı (çalışıyor). `build/MateBridge.app` yeniden derlenmedi, yani düzeltme cihazda merge ve bundle sonrası görünür.
- **Açık sorular:**
  - Düşük kare hızında (2–30 fps) kodlama yavaş: 2 fps'te 10,5 ms, 30 fps'te 7,4 ms. Muhtemelen güç/frekans durumu; ucuz düğme bulunmadı.
  - `docs/LOGGING.md` encoder olaylarını listelemiyor, yeni `ev=input_retag` için ekleme gerekmedi.
