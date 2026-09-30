---
id: T-028
title: Hızlı yeniden bağlanmada siyah ekran — sanal ekran yeniden kullanılınca tablet hiç kare çözmüyor
status: todo
phase: 2
owner: orchestrator
depends_on: [T-014, T-015]
decisions: []
files:
  - docs/NOTES.md
  - backlog/tasks/T-028-black-screen-on-display-reuse.md
---

## Amaç

Tablet, host'un 10 saniyelik sanal ekran bekleme süresi (`display_grace_started seconds=10`) dolmadan yeniden bağlanırsa (`display_reused`) ekran siyah kalıyor. Kontrol ve girdi çalışıyor, görüntü yok. Kök nedeni bulup düzeltmek; düzeltme kartı (host ve/veya tablet) bu karttan açılır.

## Bilinenler (2026-09-30, T-025 canlı oturumu)

- **Tekrarlanabilir:** `am force-stop` + 2 sn sonra `am start` → her seferinde siyah (3/3). 15 sn bekleyip başlatınca (`display_teardown` → `display_created`) görüntü geliyor (3/3). Kullanıcı bunu kabloyu çekip geri takınca ve uygulamayı kapatıp açınca gördü.
- **Host:** `display_reused`, `video_streaming`, `keyframe_request reason=0`; ilk saniyede `sent_frames=3` (≈54 KB), `send_failures=0`. Ekran durağansa sonrası `sent_frames=0`.
- **Tablet:** `codec_start` var, `output_format` **yok**. İlk saniye `recv=1 dec=0 shown=0 drop=0 bytes=38977`. Ekran hareketliyken de `recv=59 dec=0` (16:55:36): kareler geliyor, hiçbiri çözülmüyor. Tablet anahtar kare de istemiyor (host'ta `keyframe_request reason=2` yok).
- **Çalışan durumda** (yeni ekran): `output_format` 220 ms içinde, ilk saniye `recv=52 dec=51`.
- Mac'in ekranı siyah değil (ekran görüntüsünde Krita görünüyor); veri adb tüneline yazılıyor.
- Host kodu kâğıt üzerinde doğru: `VideoPipeline.prepareForNewConsumer()` kuyruğu `[CODEC_CONFIG]` ile sıfırlıyor ve son tamponu anahtar kare olarak yeniden kodlatıyor (`HEVCEncoder.requestKeyframe(resubmitNow:)`).

## Denenecek hipotezler

1. Yeniden kullanım yolunda ilk gönderilen kare gerçek bir IDR değil ya da `CODEC_CONFIG` hiç gitmiyor/yanlış sırada gidiyor (3 kare gönderildi, tablet 1 kare saydı: hangi üçü?).
2. Yeniden kodlanan "son tampon" anahtar karesi çözülebilir değil (aynı `CVPixelBuffer`'ın ikinci kez kodlanması, PTS sırası).
3. Tablet tarafı: `CODEC_CONFIG` sonrası ilk kareyi kuyruğa vermiyor ya da çözücü çıktı vermeyince anahtar kare istemiyor (kurtarma yok).

İlk adım: bağlantının iki ucunda ilk 5 mesajın bayraklarını ve boyutlarını logla/dök (host `--dump-video` ya da geçici log), yeni ekran ve yeniden kullanım durumlarını karşılaştır.

## Kabul kriterleri

- [ ] Kök neden NOTES'ta, kanıtıyla.
- [ ] Düzeltme kartı açıldı ve merge edildi; 2 sn içinde yeniden bağlanmada görüntü 1 sn içinde geliyor (5/5), durağan ekranda da.
- [ ] Tablet, kare alıp N ms içinde hiç çıktı üretemezse anahtar kare istiyor (kurtarma) — ya da neden gerekmediği yazılı.

## Geçici çözüm

Yeniden bağlanmadan önce 15 sn beklemek (ekran kapanıp yeniden kurulur).

## Plan

_(Orkestratör doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
