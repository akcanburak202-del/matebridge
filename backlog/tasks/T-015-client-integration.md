---
id: T-015
title: Android entegrasyonu — oturum + görüntü, tam ekran, istatistik katmanı
status: review
phase: 1
owner: android-client-dev
depends_on: [T-012, T-013]
decisions: [0004]
files:
  - client-android/app/src/main/
  - client-android/app/src/test/
---

## Amaç

Bağlı oturumda video bağlantısındaki kareleri tam ekran göstermek, STATS göndermek ve ekran üstü istatistik katmanı sunmak.

## Kabul kriterleri

- [x] Bağlanınca tam ekran, immersive, yatay, ekran açık kalır. Video yüzeyi ↔ normalize koordinat dönüşümü tek yerde (siyah bant dahil, PROTOCOL.md §1).
- [x] Saat farkı tahmini (§6) ve `STATS` her 1 sn.
- [x] İstatistik katmanı (aç/kapa): FPS, bitrate, çözme süresi, tahmini gecikme, atılan kare.
- [x] Arka plana geçince video durur, geri gelince keyframe istenir. Bağlantı yoksa "Bağlantı yok" ekranı.
- [x] `./scripts/check.sh` geçiyor.

## Plan

- Saf mantık `stream/`: `ClockSync` (min-rtt ofset, §6), `VideoViewport` (tek koordinat dönüşümü, siyah bant dışlanır), `StatsFormat` (STATS mesajı + katman metni). `VideoStats` gecikme hook'u (`latencyOf`) ve `latencyAvgUs` kazanır.
- `SessionListener.onPong`; `MainActivity` SurfaceView'ı akış oranına oturtur (yüzey = video alanı), STREAM_CONFIG'te renderer kurar, yüzey yokken kare vermez, 500 ms'de keyframe yeniden ister, 1 sn'de STATS gönderir ve `MB/decoder`+`MB/render` `ev=stats` loglar.

## Handoff

- **Commit:** bkz. `git log task/T-015-client-integration`
- **Dokunulan dosyalar:** stream/{ClockSync,VideoViewport,StatsFormat}.kt (yeni); MainActivity.kt; session/{SessionController,Settings}.kt; video/{VideoRenderer,VideoStats}.kt; res/layout/activity_main.xml; res/values/strings.xml; test/.../stream/StreamTest.kt
- **Varsayımlar:** Bağlı + en az 1 kare gelince bağlantı paneli gizlenir, aksi halde panel (durum/IP girişi) görünür. Arka plana geçişte (onStop) oturum BYE ile kapanır (T-012 tasarımı), dönünce yeniden bağlanıp STARTUP keyframe istenir; ayrıca yüzey dönünce renderer reset+STARTUP. İstatistik katmanı: panelde düğme, video üzerinde uzun basma veya F3; seçim saklanır. Gecikme = decoder çıkışı zamanı (gösterimden birkaç ms önce). Saat: `System.nanoTime/1000` (oturum motoruyla aynı). PONG örneği motor kuyruğundan geçtiği için rtt biraz şişebilir, min-rtt filtresi bunu azaltır. Config değişiminde eski video bağlantısından gelen birkaç kare yeni renderer'a gidebilir (keyframe kapısı korur).
- **Test edilmeyenler / cihazda doğrulanacaklar:** Hepsi cihazda: (1) Mac akışı başlayınca panel kapanıp tam ekran video, çubuk yok, ekran açık kalıyor; oran farklıysa siyah bant. (2) Uzun basma/F3 ile katman: FPS, Mbps, çözme, gecikme (ofset oturmadan önce `?`), atılan. (3) `adb logcat -s 'MB/decoder' 'MB/render'`: saniyede bir `ev=stats`; Mac tarafında STATS geliyor mu. (4) Home'a çıkıp dön: video durur, dönünce yeniden bağlanıp görüntü geliyor. (5) Host'u kapat: "Bağlantı yok" paneli, host açılınca otomatik dönüş. (6) Keyframe beklerken 500 ms'de bir KEYFRAME_REQUEST (Mac logu). Activity/SurfaceView/MediaCodec bağlaması hiç çalıştırılmadı.
- **Açık sorular:** Yok. Not: input yakalama `MainActivity.viewport`'u koordinat dönüşümü için tek kaynak olarak kullanmalı.

## Review düzeltmeleri (2. tur)

- **Viewport koordinatları:** `MainActivity.viewport` gerçek yerleşmiş SurfaceView'dan (tamsayı boyut, `video.left/top`) `video` layout dinleyicisinde kurulur; **root (SurfaceView'ın ebeveyni = pencere içeriği) koordinatlarındadır**. Faz 2 girdi yakalama `root`/pencereye gelen MotionEvent ile kullanmalı; view-yerel olay için `video.left/top` eklenmeli. Config yokken/yerleşmeden önce boş (0'lar).
- **Tek uzun ömürlü `VideoRenderer`:** `reconfigure(config)` codec'i bloklamadan yeniden başlatır (yeni thread eskisini bekler); `attachSurface` de bloklamaz, yalnızca `detachSurface` en çok 300 ms bekler. Config değişiminde saklı CODEC_CONFIG silinir.
- **ClockSync** her yeni kontrol bağlantısında (`SessionListener.onSessionStart`, otomatik yeniden bağlanma dahil) sıfırlanır. Video bağlantısının `config_id`'si güncel STREAM_CONFIG ile eşleşmiyorsa kareler controller'da atılır.
- Yaşam döngüsü: `installConfig`/`render` `!started || isDestroyed` ise döner; `onDestroy` `removeCallbacksAndMessages(null)`; `onStart` ticker'ı önce siler; renderer bırakılınca katman metni temizlenir.
- **Test edilmeyen uç durumlar:** config değişiminde eski codec yavaş çıkarsa (detach_slow) yeni thread'in beklemesi; yeni video bağlantısı açılmadan UI thread reconfigure'dan önce gelen yeni-config karelerinin eski codec'e gitmesi (keyframe kapısı + 500 ms yeniden istek toparlar); cihaz dönmesi/çoklu pencere ile viewport değişimi; onStop sonrası gelen geç callback'ler.
