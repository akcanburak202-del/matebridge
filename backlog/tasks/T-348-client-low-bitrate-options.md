---
id: T-348
title: İstemci — panelde 5 ve 8 Mbps bit hızı seçenekleri
status: todo
phase: 7
owner: android-client-dev
depends_on: []
decisions: [0013]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/
  - client-android/app/src/main/res/
  - client-android/app/src/test/
  - backlog/tasks/T-348-client-low-bitrate-options.md
---

## Amaç

Karar 0013 eki (2026-10-14): normal paneldeki bit hızı seçenekleri Otomatik / 5 / 8 / 15 / 30 / 60 / 100 Mbps. Tel biçimi değişmez (host 500 kbps'e kadar kabul ediyor).

## Kapsam

1. `Bitrate.OPTIONS_KBPS`'e 5000 ve 8000 ekle (sıra yukarıdaki gibi). Varsayılan Otomatik kalır; saklanan eski değerler aynı okunur.
2. Bu listeye ya da "en düşük seçenek 15 Mbps" varsayımına dayanan her yeri bul ve doğru çalıştığını doğrula: Otomatik çözümü, Oyun modu katmanları, T-294 geri çekilme/`manual_resume`, keyframe/boyut sınırları, panel etiketleri. Davranış değişikliği gerekirse kısa yaz.
3. Uzak profil seçenekleri (0,5/1/2 Mbps) değişmez.

## Kabul

- Birim testleri: yeni seçenekler saklanır/okunur, STREAM_PREFS'e doğru gider; eski değerler değişmez.
- `./scripts/check.sh` geçer. Cihaz testi orkestratörde.

## Plan

1. `Bitrate.OPTIONS_KBPS` gets 5000 and 8000 (panel list is built from it; sanitize/Settings/StreamPrefs follow).
2. Audit of "lowest = 15 Mbps" assumptions: GameMode (`layerBitrateKbps` passes any choice through; only Otomatik maps to 60 Mbps), `filesCapBytesPerSec` (clamps to 3 MB/s at <=15 Mbps, fine for 5/8), video health/T-294 backoff (no bit rate use), labels (`Bitrate.mbps`). No behavior change needed.
3. Tests: options list, store/read, old values, labels, STREAM_PREFS, file cap at 5 Mbps, Game layer with 5/8; update the two SettingsCatalog label lists.

## Handoff

## Açık sorular
