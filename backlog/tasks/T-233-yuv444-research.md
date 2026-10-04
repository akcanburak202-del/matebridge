---
id: T-233
title: Research — 4:4:4 chroma (HEVC RExt or alternatives) for sharp coloured edges: Mac encoder support, tablet decoder support, cost
status: todo
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

_(Araştırma ajanı doldurur.)_

## Handoff

_(Araştırma ajanı doldurur.)_
