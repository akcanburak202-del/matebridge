---
id: T-050
title: Tablet — görüntü modları (Netlik / Akıcı / Performans / Performans 144): seçim, kalıcılık, STREAM_PREFS
status: todo
phase: 5
owner: android-client-dev
depends_on: [T-046]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/protocol/
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/
  - client-android/app/src/main/kotlin/dev/matebridge/client/input/KeyTracker.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/
  - backlog/tasks/T-050-client-stream-modes.md
---

## Amaç

Kullanıcı (2026-10-01) performans modu istedi (T-049'un Amaç'ı). Protokol `proto/stream-prefs` dalında (`d642157`): `0x05 STREAM_PREFS(fps, scale_permille)`. Kart dalı `main`'den açılır, `proto/stream-prefs` merge edilir. Host T-049 paralel; birlikte merge edilir.

## Kabul kriterleri

- [ ] **Kodek:** `StreamPrefs`, fixture `stream_prefs` bayt bayt.
- [ ] **Modlar** (tek yerde tanımlı tablo): Netlik = 60 fps, 1000‰; Akıcı = 120 fps, 1000‰; Performans = 120 fps, 750‰; Performans 144 = 144 fps, 750‰. Seçim `Settings`'te kalıcı; varsayılan **Akıcı** (kullanıcı 120'yi çizimde daha akıcı buldu).
- [ ] `ACCEPTED`'dan hemen sonra (T-042'deki kanıt PING'inden sonra) ve her mod değişikliğinde `STREAM_PREFS` gönderilir.
- [ ] **Seçim yolları:** bağlantı panelinde mod düğmesi ("Görüntü modu: Akıcı (120 fps)" → tıkla, döngü), yerel kısayol `Ctrl+Shift+7` (T-035/T-038 `localChord`/`localOnly` mekanizması, fiziksel konum scan 8) döngüsel değiştirir ve kısa Toast gösterir ("Performans: 120 fps, %75"). Kısayol satırı güncellenir.
- [ ] **Çözücü/gösterim:** `STREAM_CONFIG.width_px/height_px` artık sanal ekrandan küçük olabilir: çözücü o boyutla yapılandırılır, görüntü video yüzeyini (mevcut görünüm alanı/letterbox en-boy hesabı `width_pt/height_pt` ya da ekran oranıyla) doldurur; yüzey `setFixedSize` ile kodlanan boyuta ayarlanırsa donanım ölçekleyici kullanılır (öneri). Girdi koordinatları normalize, değişmez. T-046 kare hızı isteği yeni fps'i izler (144 dahil: 144 Hz modunu iste).
- [ ] İstatistik katmanı modu ve kodlanan boyutu gösterir.
- [ ] Testler: mod tablosu/döngü, kalıcılık, gönderim zamanlaması, kısayolun Mac'e gitmemesi, küçük boyutlu STREAM_CONFIG yerleşimi. `./scripts/check.sh` (T-049 ile birlikte) geçiyor.

## Kapsam dışı

- Host (T-049). Cihaz testi orkestratörde.

## Plan

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
