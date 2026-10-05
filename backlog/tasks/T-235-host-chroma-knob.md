---
id: T-235
title: Host dev knob MATEBRIDGE_CHROMA=420|sharp_bilinear|sharp_nearest|444 — sharp-YUV (luma adjustment) 4:2:0 via a Metal pass, plus a native 4:4:4 probe value; colour test page
status: todo
phase: 6
owner: mac-host-dev
depends_on: [T-233]
decisions: []
files:
  - host-mac/Sources/MateBridgeHost/Video/
  - host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift
  - host-mac/Sources/MateBridgeCore/Video/
  - host-mac/Tests/MateBridgeCoreTests/Video/
  - host-mac/Package.swift
  - tools/chroma-test/
  - docs/KNOBS.md
  - docs/LOGGING.md
  - backlog/tasks/T-235-host-chroma-knob.md
---

## Amaç

T-233 araştırmasının (docs/research/2026-10-05-yuv444.md §3b ve "Kart A") uygulaması. Kullanıcı 2026-10-05: "deneriz, hoş görünüyorsa kullanırız". Dock'taki kırmızı ikon gibi doygun renk kenarlarındaki basamaklanmayı (4:2:0 luma hatası) host tarafında, protokole ve istemciye dokunmadan azaltmak; ayrıca tablet çözücüsünün gerçek 4:4:4 akışına ne yaptığını bir kez görmek.

## Bağlam

- Geliştirici anahtarı `MATEBRIDGE_CHROMA` (decision 0026 sınıfı, env, host `knobs=` alanı). Varsayılan `420` = bugünkü yol bit-bit aynı (SCK `420f` → VT).
- `sharp_bilinear` / `sharp_nearest`: SCK `BGRA` → Metal compute kernel: 2×2 renk alt örnekleme + piksel başına luma ayarı (araştırmadaki ikili arama ya da libwebp sharpyuv benzeri yinelemeli yöntem; planda seç), çözücünün rengi çift doğrusal ya da en yakın komşu büyüttüğünü varsayan iki değişken → `420f` CVPixelBuffer (aynı 709/sRGB/709 etiketleri, T-113) → mevcut HEVCEncoder. Metal pass süresi ve yakalama→kodlama süresi loglanır (`ev=chroma_stats` 10 sn pencerede p50/p95).
- `444`: SCK `BGRA` + VT profil `"HEVC_Main444_AutoLevel"` yalnız hızlı yolda (LLRC açıksa reddet ve `420`'ye dön, logla). Her oturumda SPS `chroma_format_idc` ayrıştırılıp `ev=chroma_config requested= applied= chroma_format_idc=` yazılır (araştırma: VT LLRC'de sessizce 4:2:0'a düşebiliyor). İstemci değişmez; tabletin çözücüsü hata verebilir ya da bozuk görüntü gösterebilir. Bu değer yalnız bir kez denemek içindir.
- Dikkat: araştırma host'un akışa chroma location yazmadığını not etti (yarım piksel renk kayması olabilir). Planda değerlendir; sharp değerlerinde VUI `chroma_sample_loc` yazılabiliyorsa yaz (yalnız knob açıkken).
- GPU maliyeti: Oyun modunda da çalışır (deneme). Karar sonuçlara göre (kart B).
- Test sayfası: `tools/chroma-test/index.html` (tek dosya, çevrimdışı): kırmızı/mavi/yeşil/mor ikon benzeri yuvarlak kareler gri ve koyu zeminde, renkli yazı (12–16 px), 1 px renkli çizgiler, kırmızı-mavi ızgara. Kullanıcı Safari'de açar.
- Pencere açma, sanal ekran kurma, çalışan host'a dokunma. Metal ve VT kısa sentetik denemeler kabul (canlı akış kodlayıcıyı paylaşır).

## Kabul kriterleri

- [ ] [XCTest] Knob ayrıştırma ve geri dönüş kararları (LLRC + 444 → 420) saf fonksiyon olarak test edilir; luma ayarının CPU referans uygulaması küçük sentetik bloklarda (kırmızı/gri kenar) bilinen PSNR iyileşmesini verir; Metal kernel çıktısı CPU referansıyla ±1 kod değerinde eşleşir (Metal test ortamında yoksa probe/CLI ile, Handoff'ta).
- [ ] Varsayılan yolda yakalama biçimi ve kodlayıcı ayarları değişmez.
- [ ] `ev=chroma_config`, `ev=chroma_stats` docs/LOGGING.md'de; knob docs/KNOBS.md'de.
- [ ] `./scripts/check.sh` geçer.
- [ ] [device, orkestratör + kullanıcı] Dört değer sırayla: test sayfası ve Dock (kullanıcı gözle; gerekirse telefon fotoğrafı), `444` için istemci `ev=decoder_output_format`/hata, gecikme farkı. Sonuç NOTES'a; olumluysa kart B (karar).

## Plan

_(Ajan kodlamadan önce doldurur.)_

## Handoff

_(Ajan bitirince doldurur.)_
