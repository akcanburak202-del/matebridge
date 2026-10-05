---
id: T-242
title: Client — "Otomatik" bit rate picked inside Oyun/Çizim must mean the layer default (60 Mbps), not the host formula
status: in_progress
phase: 6
owner: android-client-dev
depends_on: []
decisions: [0014, 0030]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/
  - client-android/app/src/main/kotlin/dev/matebridge/client/settings/
  - client-android/app/src/test/kotlin/dev/matebridge/client/
  - backlog/tasks/T-242-client-auto-bitrate-in-mode-layer.md
---

## Amaç

Cihaz 2026-10-05: kullanıcı Oyun modundayken panelden bit hızını "Otomatik"e aldı → host 20 Mbps uyguladı (`ev=profile fps=60 bitrate_kbps=20000 bitrate_source=prefs display=2240x1472@1x dynamic_range=hdr10`). Neden: `GameModeSettings.defaults()` kayıtlı değer Otomatik iken katmana `GAME_BITRATE_KBPS` (60 Mbps) koyuyor, ama katman açıkken `setBitrateKbps(0)` `write()` ile katmanın kopyasını 0'a çeviriyor; STREAM_PREFS 0 gider, host modun formülünü uygular (2240@60 → 19,2 → alt sınır 20 Mbps). Oyun moduna Otomatik'le girince 60, içerideyken Otomatik seçince 20: tutarsız.

## Kabul kriterleri

- [ ] [JVM] Oyun ve Çizim katmanı açıkken Otomatik seçilirse etkin bit hızı katman varsayılanı (`GAME_BITRATE_KBPS`) olur; STREAM_PREFS'te 60000 gider. Günlük'te Otomatik bugünkü gibi 0 (host formülü).
- [ ] [JVM] Panel etiketi katman açıkken "Otomatik (60 Mbps)"; seçili işaret Otomatik'te kalır.
- [ ] [JVM] Kalıcı (kaydedilen) değer kuralı değişmez (0014 §3 yazma kuralı).
- [ ] `./scripts/check.sh` geçer.

## Plan

1. `GameModeSettings` (stream/GameMode.kt): katman kullanıcının bit hızı **seçimini** ayrıca tutar (`layerBitrateChoice`, 0 = Otomatik). `Values.bitrateKbps` (etkin, gönderilen değer) seçimden türetilir: katman açıkken Otomatik → `GAME_BITRATE_KBPS` (yeni `layerBitrateKbps(choice)`; `defaults()` de bunu kullanır). `setBitrateKbps(0)` katmanda artık 0 değil 60000 yazar → `prefs()` STREAM_PREFS'te 60000 gönderir. Günlük'te Otomatik bugünkü gibi 0.
2. Genel `bitrateKbps` getter'ı panelin seçimini döndürür (katmanda Otomatik → 0), böylece seçili işaret Otomatik'te kalır. `effective()`/`prefs()`/`ev=mode_layer` çözülmüş değeri (60000) kullanmaya devam eder. Kalıcı yazma kuralı (0014 §3) değişmez: katmanda yazılan seçim kaydedilmez.
3. Panel etiketi: `SettingItem.Option` etiketi lambda ile okunabilir hale gelir (mevcut `String` kurucusu korunur); `SettingsViews` yenilemede buton metnini günceller. Bit hızı seçeneklerinde Otomatik, katman açıkken "Otomatik (60 Mbps)" (`GameModeSettings.bitrateOptionLabel(layer, kbps)`), Günlük'te "Otomatik".
4. JVM testleri: katmanda Otomatik seçince prefs 60000 / seçim 0 / kayıt değişmez (Oyun ve Çizim); Günlük'te 0; etiket metinleri; catalog'da etiketin mod değişince yenilenmesi.
5. MainActivity dosya listesinde değil: `bitrateKbps`'i panel seçimi, `wanted_kbps`/`bitrate_setting` log alanları için kullanıyor; bunlar katmanda Otomatik iken artık 0/"auto" gösterir (ayar = Otomatik). Handoff'ta not edilir.

## Handoff

_(Ajan bitirince doldurur.)_
