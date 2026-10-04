---
id: T-226
title: Research — can MateBridge stream HDR (HDR virtual display → 10-bit HEVC → HDR10/HLG on the tablet)? Feasibility and cost, no product code
status: in_progress
phase: 6
owner: orchestrator
depends_on: [T-188]
decisions: []
files:
  - docs/research/2026-10-04-hdr-feasibility.md
  - probes/hdr-probe/
  - backlog/tasks/T-226-hdr-feasibility-research.md
---

## Amaç

Kullanıcı (2026-10-04): Resident Evil 4 ayarlarında HDR açılamıyor ("monitörünüzün HDR özelliği olduğundan emin olun"); tablet HDR destekliyor. Bugün hat baştan sona SDR (T-188): sanal ekran SDR, SCK 8-bit, HEVC Main, tablette SDR yüzey. Bu kart kod yazmadan önce şu soruya cevap verir: **MateBridge HDR akıtabilir mi, hangi halka engel, maliyeti ne?** Çıktı bir araştırma raporu ve (varsa) küçük, izole bir prob; ürün kodu yok.

## Bağlam

- **Tablet:** `dumpsys display` → `HdrCapabilities{mSupportedHdrTypes=[2, 3]}` (HDR10, HLG), `mMaxLuminance=500`, `mMaxAverageLuminance=102`, `mMinLuminance=1`; geniş renk paneli (Display P3). SurfaceFlinger BT.709 SDR videoyu P3'e doğru dönüştürüyor (T-188).
- **Zincir ve açık sorular (halka halka):**
  1. **Sanal ekran HDR bildirebilir mi?** `CGVirtualDisplay` / `CGVirtualDisplaySettings` / `CGVirtualDisplayDescriptor` (özel API, `VirtualDisplay` tipinin arkasında) macOS 27'de HDR/EDR ile ilgili bir özellik sunuyor mu (ör. `hdrSupported`, EDR headroom, renk alanı/transfer, `maxLuminance` alanları)? Objective-C runtime'dan (sınıf yöntem/özellik listesi) ve kamuya açık kaynaklardan (BetterDisplay gibi araçların HDR sanal ekran iddiaları, açık kaynak projeler) belirlenir. Oyunların HDR'yi açması için macOS'un ekranı "HDR yetenekli" saymasının koşulu (`NSScreen.maximumPotentialExtendedDynamicRangeColorComponentValue` > 1, `CGDisplayCopyColorSpace`, sistem ayarlarında "Yüksek Dinamik Aralık" anahtarı) ne?
  2. **Yakalama:** ScreenCaptureKit HDR yakalama (`SCStreamConfiguration.captureDynamicRange` = `.hdrLocalDisplay` / `.hdrCanonicalDisplay`, piksel biçimi `kCVPixelFormatType_ARGB2101010LEPacked` / 10-bit YCbCr, renk alanı/transfer etiketleri) sanal ekranda çalışır mı; gecikme ve bant genişliği etkisi.
  3. **Kodlama:** VideoToolbox HEVC Main10 + PQ (HDR10) ya da HLG, donanımda gerçek zamanlı; HDR statik metadata (mastering display, MaxCLL/MaxFALL) eklenmesi; bugünkü hızlı profil (T-053/T-113) ile uyum, 120 fps'te enc süresi.
  4. **Tel biçimi:** `CODEC_CONFIG`/`STREAM_CONFIG` renk bilgisi (primaries/transfer/matrix/range, bit derinliği, HDR metadata) için protokol değişikliği gerekir mi (VPS/SPS VUI yeterli mi)? Gerekiyorsa en küçük değişiklik taslağı (yalnız öneri; protokolü orkestratör değiştirir).
  5. **Çözme ve gösterim:** HiSilicon HEVC decoder Main10 destekliyor mu (`MediaCodecList` profil/seviye: `HEVCProfileMain10`, `HEVCProfileMain10HDR10`); `SurfaceView` + `MediaCodec` çıkışında `KEY_COLOR_TRANSFER=ST2084/HLG`, `KEY_HDR_STATIC_INFO`; HarmonyOS 4.3 HDR video katmanını gerçekten HDR modunda sunuyor mu (`IsHdrLayerPresent`), parlaklık ve güç etkisi.
  6. **SDR içerik:** HDR akış açıkken masaüstü/yazı (SDR) doğru görünür mü (SDR beyaz seviyesi, tone mapping); bu yüzden HDR yalnız Oyun modunda / isteğe bağlı mı olmalı?
- **Okunabilecekler:** tablette `MediaCodecList` ve `dumpsys display` yalnız okuma; Mac'te ObjC runtime ile sınıf/özellik listesi (ekran kurmadan). Bir halka yalnız deneyle cevaplanabiliyorsa `probes/hdr-probe/` altında izole bir prob yazılır, **ama çalıştırılması (sanal ekran kurmak, tablette uygulama açmak) kullanıcı onayı ve tek seferde bir cihaz testi kuralıyla orkestratör tarafından yapılır.**

## Kapsam dışı

- Ürün kodu (host/istemci), protokol değişikliği, bağımlılık ekleme.
- 4:4:4 renk (ayrı konu).

## Kabul kriterleri

- [ ] [doc] `docs/research/2026-10-04-hdr-feasibility.md`: her halka için cevap (evet / hayır / bilinmiyor + nasıl öğrenilir), kanıt (kaynak bağlantısı, runtime çıktısı, cihaz okuması), engel varsa hangisi.
- [ ] [doc] Uygulanabilirse: önerilen mimari (hangi modda, hangi biçim: HDR10 mı HLG mi), protokol etkisi taslağı, kart bölümlemesi ve kaba maliyet; gecikme/bant/güç riski.
- [ ] [doc] Uygulanamazsa: hangi halkanın neden engel olduğu ve neyin değişmesi gerektiği (ör. macOS sürümü, kamuya açık API).
- [ ] [device, isteğe bağlı] Prob gerekirse orkestratör kullanıcı onayıyla çalıştırır ve sonucu rapora ekler.

## Plan

1. Kod okuması: bugünkü SDR zinciri (`VirtualDisplay.swift`, `ScreenCapture.swift`, `HEVCEncoder.swift`, `VideoSettings.swift`, `VideoRenderer.kt`, `docs/PROTOCOL.md` STREAM_CONFIG) — HDR için değişecek noktaların listesi.
2. Mac, salt okuma: ObjC runtime ile `CGVirtualDisplay*` sınıflarının özellik/yöntem listesi (örnek oluşturmadan); `VTCopySupportedPropertyDictionaryForEncoder` ile HEVC Main10/HDR anahtarları (oturum yok); SDK başlıklarında `captureDynamicRange`, EDR anahtarları.
3. Tablet, salt okuma: `dumpsys display`, `dumpsys SurfaceFlinger` (HDR katman/renk modu), `media_codecs*.xml` ve `dumpsys media.codec` ile HEVC Main10/HDR10 profilleri; `getprop`.
4. Web: BetterDisplay/açık kaynak sanal ekran projelerinde HDR iddiaları, CGVirtualDisplay class-dump'ları, SCK HDR yakalama, VT HEVC Main10 PQ/HLG, Android HDR10 SurfaceView, Huawei HDR video.
5. Yalnız deneyle cevaplanacak halka varsa `probes/hdr-probe/` altında küçük, izole prob kaynağı + çalıştırma talimatı (çalıştırılmaz).
6. Rapor `docs/research/2026-10-04-hdr-feasibility.md`: halka halka evet/hayır/bilinmiyor + kanıt, engel, önerilen mimari, protokol taslağı, kart bölümlemesi, maliyet/risk.

Riskler: canlı kullanıcı oturumu — tablette yalnız okuma komutları; Mac'te ekran/sanal ekran kurulmaz, pencere açılmaz.

## Handoff

_(Araştırmacı bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulananlar:**
- **Açık sorular:**
