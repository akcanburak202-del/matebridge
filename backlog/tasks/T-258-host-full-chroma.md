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
- **Anahtar kareler:** STARTUP/DECODE_ERROR/bilinmeyen `view` → iki akış (yardımcınınki bir kare kaydırılabilir); `view = 1` → yalnız yardımcı (+ onun CODEC_CONFIG'i). T-122 birleştirme her akışta ayrı. Periyodik IDR ikisinde.
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

Dal: `task/T-258-host-full-chroma` (T-257 üzerine). Protokole dokunulmaz.

1. **Codec (Core):** `StreamConfig.chromaLayout` (eski reserved), `VideoFrame.view`, `Message.keyframeRequest(reason, view:)` (isteğe bağlı ikinci bayt; yoksa `nil` = iki akış), `Capabilities.fullChroma` (bit11), `ChromaPreference.full` (2). Fixture testleri yeni beş dosyayı kapsar.
2. **Politika (Core, saf):** `VideoSettings` — `clientFullChroma` (HELLO bit11), `fullChromaGranted` (bit11 + bu oturumda gelen `chroma = 2` + fps 60 + doğal ekran + ölçek 1000 + SDR + HEVC + çalışma zamanı geri düşüşü yok), `packedChroma` (granted + env), `streamConfig.chromaLayout`. `applying(..., fullChroma: FullChromaSession)`: hatırlanan tercih (`prefsFromThisSession = false`) 1 gibi uygulanır; geri düşüşte `.normal`. `ChromaMode.packed444`, `ChromaPolicy` (env önceliği; `packed444` onay yoksa keskin yola düşer), `ChromaConfigLog` (`layout=packed444`).
3. **Paketleyici:** `AVC444v2` CPU referansı + Metal çekirdeği kaynağı (`PackedChromaKernel`, T-255 `pack_v2` birleşik tek geçiş, `pick`) Core'da; `PackedChromaPacker` (Host/Video, `ChromaConverter` kalıbı: IOSurface havuzu, doku önbelleği, T-113 etiketleri iki çıktıya). Testler: CPU referansı kendi içinde gidiş-dönüş, GPU çıktısı CPU ile bit-tam (Metal yoksa atlanır).
4. **İkinci VT oturumu:** `PackedAuxEncoder` (Host/Video): aynı hızlı profil, `AverageBitRate`/`DataRateLimits` = ana hedefin %50'si, en çok 2 uçuşta kare (doluysa yardımcı atılır ve yardımcı IDR beklenir), kendi CODEC_CONFIG'i (`view = 1`). `HEVCEncoder` paketleyiciyi owner kuyruğunda çalıştırır (`send`): ana tampon ana oturuma, yardımcı tampon `PackedAuxEncoder`'a aynı `capture_time_us` ve PTS ile. Yardımcı IDR bayrağı ayrı (`requestKeyframe(view:)`); refine kareleri yardımcı IDR'ı yemez, bekleyen yardımcı IDR refine trenini bitirir; refine bayt hesabı toplam (ana + yardımcı tahmini).
5. **Sıra ve sınır (Core, saf):** `PackedSendArbiter`: önce ana; yardımcı yalnız gönderilmiş bir ana karenin `capture_time_us`'u ile gider (ana henüz gelmediyse bekler, ana atılmışsa yardımcı atılır ve yardımcı IDR istenir). `VideoFrameQueue`'ya `tryPop/peek/breakChain/observer` eklenir; yardımcı kuyruk kapasitesi 2. `VideoSender` yardımcı kuyruğu alır (`frame_seq` akış başına, soket tıkanınca zaten yalnız ana önce çekilir, yardımcı bekler/atılır). Yardımcı IDR/CODEC_CONFIG yeniden eşzamanlama (`view` 1 ve 2) VideoPipeline'da.
6. **Geri düşüş (Core, saf):** `PackedChromaMonitor`: pencere (1 s) başına yardımcı kaybı > %5, 3 ardışık pencere, ya da VT/Metal/oturum hatası → `chroma_fallback reason=`. `StreamCoordinator`: yeni `config_id`, `chroma_layout = 0` (normal 4:2:0), tercih saklı kalır; sonraki ekran kipi değişiminde (`sameStreamMode`) bayrak silinir, yeniden denenir.
7. **Log/belge:** `ev=chroma_config layout=packed444`, `ev=chroma_stats` (paketleyici GPU ms, yardımcı enc ms, yardımcı/ana bayt oranı, yardımcı kaybı), `ev=chroma_fallback`; `docs/LOGGING.md`, `docs/KNOBS.md`.
8. **Test:** Core birim testleri (politika, env/HDR/onay, `view` yönlendirme, sıra, kuyruk sınırı, geri düşüş kararı, paketleyici bit-tamlığı). `./scripts/check.sh`.

## Handoff

## Open questions
