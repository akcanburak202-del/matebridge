---
id: T-313
title: Host — ölü ve yalnız testte kullanılan kod, küçük tekrarlar, test kopyaları (T-297 parti 4) ve REFINE anahtarları ev=profile'da
status: todo
phase: 7
owner: mac-host-dev
depends_on: [T-302, T-304, T-309, T-311]
decisions: []
files:
  - host-mac/Sources/
  - host-mac/Tests/
  - backlog/tasks/T-313-host-dead-code.md
---

## Amaç

T-297 parti 4 (`docs/reviews/2026-10-08/simplification.md`). Kanıtlar (dosya:satır; T-302/T-304/T-309/T-311 sonrası kaymış olabilir, okuyarak doğrula):
- `docs/reviews/2026-10-08/agents/simp-a-host-video.md`: A2, A3, A4, A5, A6, A7, A9, A13;
- `simp-b-host-session.md`: B2, B3, B6 (ölü kısımlar ve kopya temizlik; dinleyici birleştirmesi **hariç**), B8, B10, B11, B12;
- `simp-e-protocol.md`: E5, E7, E8 (Swift kısmı), E11.

## Kabul

1. **Ölü ve test-yalnız kod:** A3, B10 ve E5 listeleri silinir. A5 testleri üretim API'lerine geçer. A9 CPU referans modelleri (`SharpYUV` CPU dönüşümü, `AVC444v2` paketleme) test hedefine taşınır; üretimde yalnız sabitler, doğrulayıcılar ve kernel kaynakları kalır.
2. **Sıcak yol, davranış aynı:**
   - **A2+A7:** kodlanmış kare tek kopyayla Annex-B'ye; 4 baytlık uzunluklar yerinde başlangıç koduna çevrilir. Çok parçalı `CMBlockBuffer` yolu ve bozuk girdi kontrolleri kalır. Yeni test, eski `AnnexB.convert` ile bayt bayt eşitliği gösterir. Son `CMFormatDescription` önbellekte tutulur; aynı nesnede VPS/SPS/PPS yeniden çıkarılmaz, CODEC_CONFIG duyurusu her değişimde gider.
   - **A6:** kare başına renk etiketleri Core sabitinden.
   - **A13:** `mach_timebase_info` önbellekte.
3. **Tekrarlar ve yapı:**
   - A4 `VideoSender` tek yazma yolu.
   - B2 `nw` artıkları; B3 türetme yardımcısı (`session_without_config` ölü dalı).
   - B6 ölü parçalar ve 6 haritalı kopya temizlik.
   - B8 tek en-son-değer posta kutusu.
   - B12 `.teardown(reason)`.
   - E7 Ping/Pong/Stats/VideoHello struct üstüne, `SessionServer` VIDEO_HELLO için `Message.decode`.
   - E11 `SessionMachine` satır içi eşleşme anahtarı yolu kalkar; testler async yola geçer.
4. **Testler:** B11 kopya lease testleri silinir; lease paketi `DisplayLeaseTests.swift`'e taşınır.
5. **`REFINE`:** `MATEBRIDGE_REFINE`, `_MS`, `_KB` ve `_FRAMES` `StreamProfileLog.knobAllowList`'e eklenir (KNOBS açık nokta 3).
6. **Değişmeyenler:** protokol baytları (fixture testleri), girdi güvenliği yolları, `EncoderSubmitOrder` tek sahip ve `VirtualDisplay` yalıtımı.
7. **Handoff:** silinen satır sayısı ve gerekirse LOGGING önerisi. Cihaz kontrolü orkestratörde (Keskin renk, Tam renk, HDR açılışı, yeniden bağlanma).

## Plan

## Handoff

## Open questions
