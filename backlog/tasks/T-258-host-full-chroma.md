---
id: T-258
title: Host — packed full chroma (decision 0034): codecs, Metal AVC444v2 packer, second VT session, pairing, fallback
status: ready
phase: 6
owner: mac-host-dev
depends_on: [T-257, T-253]
decisions: [0034, 0033, 0032]
files:
  - host-mac/Sources/MateBridgeCore/
  - host-mac/Sources/MateBridgeHost/Video/
  - host-mac/Sources/MateBridgeHost/Session/
  - host-mac/Tests/
  - docs/LOGGING.md
  - docs/KNOBS.md
  - backlog/tasks/T-258-host-full-chroma.md
---

## Amaç

Karar 0034'ün host tarafı. Protokol ve fixture'lar `task/T-257-full-chroma-protocol` dalında; **bu dalın üzerine kur** (`git checkout -b task/T-258-host-full-chroma task/T-257-full-chroma-protocol`). Protokolü değiştirme; uyuşmazlık görürsen Open questions'a yaz.

## Bağlam

- **Codec (Swift):** `STREAM_CONFIG.reserved` → `chroma_layout`, `VIDEO_FRAME.reserved` → `view`, `KEYFRAME_REQUEST` isteğe bağlı `view` (yoksa = iki akış; bilinmeyen = iki akış), `STREAM_PREFS.chroma` `2`. Bütün fixture testleri (yeni beş dahil) geçmeli.
- **Politika:** `chroma = 2` yalnız PROTOCOL §0x05 "Tam renk" koşullarında uygulanır (fps 60, doğal ekran, ölçek 1000, SDR); değilse `1` gibi (keskin). `MATEBRIDGE_CHROMA` önceliği korunur (yeni geliştirici değeri `packed444`). HDR kuralı (0032) aynen.
- **Paketleyici:** T-255 probunun Metal çekirdeği (`probes/yuv444-probe`, birleşik tek geçiş, `pick` ana renk seçimi) ürün koduna taşınır; `ChromaConverter` kalıbı (IOSurface havuzu, doku önbelleği). Çıktı iki `420f` tampon; T-113 etiketleri (oturum etiketleri, `retagForSession`) ikisine de: T-255 M4 bit-tamlık koşulu.
- **İki VT oturumu:** mevcut `HEVCEncoder` ana; ikinci örnek yardımcı (aynı hızlı profil, ayrı `AverageBitRate`/`DataRateLimits` = ana hedefin %50'si). Ana yardımcıyı beklemez; aynı yakalama için ana önce gönderilir; yardımcı `capture_time_us` = ananınki; `frame_seq` akış başına. Yardımcı kuyrukta en çok 2 kare, soket tıkanınca önce yardımcı atılır (PROTOCOL §5).
- **Anahtar kareler (Codex T-257 r2 netleştirmesi):** hangi akışın IDR alacağını **`view` seçer** (yok / `2` / bilinmeyen → iki akış, yardımcınınki bir kare kaydırılabilir; `0` yalnız ana; `1` yalnız yardımcı). `reason` yalnız CODEC_CONFIG'in yeniden gönderilip gönderilmeyeceğini belirler (STARTUP/DECODE_ERROR/bilinmeyen → seçilen akış(lar)ın CODEC_CONFIG'i yeniden; FRAMES_DROPPED → hayır). T-122 birleştirme her akışta ayrı. Periyodik IDR ikisinde.
- **T-253 netleştirme:** trenler iki akışta da çalışmalı (aynı yeniden gönderim yolu iki oturuma); bayt tavanı toplam. Codex'in T-253'te bulduğu sıralama kuralları (gerçek kare önceliği, bekleyen IDR) iki akış için de geçerli.
- **Geri düşüş:** yardımcı kodlama sürekli yetişemezse (pencere başına yardımcı kaybı > %5, birkaç pencere) ya da VT hatası → yeni `config_id` ile `chroma_layout = 0` (ana tek akış, normal 4:2:0 — keskin değil), `ev=chroma_fallback reason=`. Tercih korunur; sonraki ekran kipi değişiminde yeniden denenir.
- **Log:** `ev=chroma_config` (`layout=packed444`), `ev=chroma_stats` (paketleyici GPU ms, yardımcı enc ms, yardımcı/ana bayt oranı, yardımcı kaybı), `ev=chroma_fallback`. `docs/LOGGING.md`, `docs/KNOBS.md`.
- Mac'te pencere açma, uygulamayı çalıştırma; sanal ekran kurma. Komut satırı VT/Metal testleri serbest. Cihaz testi orkestratörde.

- **Oturum onayı (Codex T-257):** `HELLO.capabilities` bit11 `FULL_CHROMA`. Host: yardımcı akış yalnız bit11 + bu oturumda gelen son `STREAM_PREFS.chroma = 2` ile; hatırlanan tercih ya da `MATEBRIDGE_CHROMA=packed444` bunu aşamaz. Ana akış §5 sınırlı kuyruk kurallarına tabi; tıkanmada önce yardımcı atılır.

## Kabul kriterleri

- [ ] Fixture testleri (eski + yeni) geçer; `./scripts/check.sh` geçer.
- [ ] Birim testleri: politika (koşullar, env önceliği, HDR), anahtar kare yönlendirme (`view`), sıra (ana önce, yardımcı aynı `capture_time_us`), yardımcı kuyruk sınırı, geri düşüş kararı; paketleyici yazılım referansıyla bit-tam (T-255 testleri taşınabilir).
- [ ] Handoff: cihazda doğrulama adımları (2800 @60 Günlük, `ev=chroma_stats`, motor doluluğu, Wi-Fi bayt oranı, geri düşüş tetikleme yolu).

## Plan

## Handoff

## Open questions
