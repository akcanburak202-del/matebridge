---
id: T-233
title: Research — 4:4:4 chroma (HEVC RExt or alternatives) for sharp coloured edges: Mac encoder support, tablet decoder support, cost
status: in_progress
phase: 6
owner: orchestrator
depends_on: []
decisions: []
files:
  - docs/research/2026-10-05-yuv444.md
  - backlog/tasks/T-233-yuv444-research.md
---

## Amaç

NOTES 2026-10-04 ~22:45: Dock'taki Apple Music ikonu tablette kenarlarda basamaklı. Neden 4:2:0 renk alt örnekleme (doygun kırmızı ile gri arka plan arasındaki kenar parlaklıkta zayıf, renkte güçlü); bit hızından bağımsız (T-188). Kullanıcı 2026-10-05 araştırmayı onayladı. Renkli yazı, sözdizimi renklendirmesi ve ince renkli çizgiler de aynı sorundan etkilenir.

## Sorular

1. **Mac kodlayıcı:** Apple M-serisi (bu Mac: M6) VideoToolbox HEVC 4:4:4 (Main 4:4:4 / RExt, 8 ve 10 bit) donanım kodlamasını destekliyor mu? Hangi pixel format (`444v`/`444f`, `y416`), hangi profil sabitleri, düşük gecikme (`EnableLowLatencyRateControl`) ile birlikte çalışıyor mu? ScreenCaptureKit 4:4:4 ya da BGRA verebiliyor mu, dönüşüm maliyeti nedir? Mümkünse Mac'te salt sorgu ile doğrula (`VTCopySupportedPropertyDictionaryForEncoder`, küçük bir CLI ile sentetik kare kodlama). Canlı akış varken tek donanım kodlayıcısı paylaşılır: kısa bir deneme kabul, uzun benchmark değil. Pencere açma, sanal ekran kurma.
2. **Tablet çözücü (HiSilicon `OMX.hisi.video.decoder.hevc`, HarmonyOS 4.3):** HEVC RExt 4:4:4 profili destekleniyor mu? Salt okuma adb: `dumpsys media.player`, `/vendor/etc/media_codecs*.xml`, `MediaCodecList` profil/seviye listeleri (T-226'nın yaptığı gibi). APK kurma, uygulama başlatma yok.
3. **Alternatifler** (4:4:4 donanımda yoksa): (a) 2× genişlikte luma + ayrı renk düzlemi gibi "4:4:4-over-4:2:0" paketleme hileleri (ör. Microsoft RDP AVC444, ikinci akış); (b) host tarafında renk kenarı keskinleştirme / chroma-aware ölçekleme; (c) yalnız durağan bölgeler için kayıpsız ya da yüksek renkli yama; (d) AV1 4:4:4 (tablet AV1 çözücüsü var mı). Her biri için gecikme, bit hızı, kod emeği.
4. **Bütçe:** 4:4:4 bit hızı ve kodlama/çözme süresi 4:2:0'a göre ne kadar artar (120 fps / 2800×1840 için çözücü sınırı: T-222 notları, decoder ~9 ms).
5. **Öneri:** yap / yapma / hangi alternatif; protokol etkisi (STREAM_CONFIG'de chroma alanı gerekir mi), kart bölümlemesi, cihaz oturumu sayısı.

## Kabul kriterleri

- [ ] docs/research/2026-10-05-yuv444.md: her soruya kaynaklı cevap, [ölçüm]/[kaynak]/[çıkarım] etiketleriyle; sonunda net öneri.
- [ ] Cihaz ve Mac komutları yalnız salt okuma ya da kısa sentetik deneme; hangi komutun çalıştırıldığı yazılır.

## Plan

1. Repo bağlamı: bugünkü hat (SCK piksel biçimi, VT oturum ayarları, hızlı profil), `STREAM_CONFIG`/`CODEC_CONFIG` alanları, T-047/T-053/T-188/T-222/T-226 notları.
2. Mac (salt sorgu + tek kısa deneme): `VTCopyVideoEncoderList`, `VTCopySupportedPropertyDictionaryForEncoder` (HEVC/H.264/ProRes, 2800×1840), profil sabitleri ve kabul edilen piksel biçimleri; SCK `pixelFormat` için BGRA/`444v`/`xf44` kabulünü SDK başlığından ve preset'lerden okumak. Scratch'te küçük bir Swift CLI: sentetik 4:4:4 kareleri (birkaç kare, kısa) `Main 4:4:4` profilleriyle kodlamayı dener; oturum ayarı kabulü, çıkan SPS'teki `chroma_format_idc`/profil, kare başı süre ve bayt, LLRC ve hızlı yol. Akışı etkilememek için yalnız birkaç kare.
3. Tablet (salt okuma adb): `dumpsys media.player` HEVC/AVC/AV1/VP9 profil listeleri, `/vendor/etc/media_codecs*.xml` ve `/system/etc/media_codecs*.xml`, `getprop` (SoC, çözücü). APK yok, uygulama başlatma yok, girdi yok.
4. Web: Apple VT 4:4:4 belgeleri ve üçüncü taraf deneyimleri (Sunshine/Moonlight 4:4:4, Parsec, RDP AVC444, Chrome Remote Desktop), Kirin/HiSilicon RExt, AV1 4:4:4 (Professional profil) çözücü durumu, chroma-aware alternatifler.
5. `docs/research/2026-10-05-yuv444.md`: her soruya [ölçüm]/[kaynak]/[çıkarım] etiketli cevap, çalıştırılan komutlar listesi, bütçe tablosu, net öneri, protokol etkisi ve kart bölümlemesi.
6. Handoff doldur, commit.

## Handoff

_(Araştırma ajanı doldurur.)_
