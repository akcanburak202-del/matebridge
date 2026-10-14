---
id: T-346
title: Host — uzak oturumda tablet dosyaları (FILES_NET OPEN), tavan 0,5 MB/s
status: todo
phase: 7
owner: mac-host-dev
depends_on: []
decisions: [0035, 0038]
files:
  - host-mac/Sources/MateBridgeCore/Files/
  - host-mac/Sources/MateBridgeCore/Session/
  - host-mac/Sources/MateBridgeHost/
  - host-mac/Tests/
  - docs/LOGGING.md
  - backlog/tasks/T-346-host-remote-files.md
---

## Amaç

Karar 0038 eki (2026-10-14); PROTOCOL.md §4 STREAM_PREFS "Uzak profil" ve §4 "Dosya bağlantısı" (hız tavanı). Uzak oturumda (`link = 1`) Mac menüsündeki "Tablet dosyalarını aç" Wi-Fi'daki gibi çalışmalı.

## Kapsam

1. `link = 1` iken `FILES_NET OPEN`'ı engelleyen kuralı kaldır. Menü öğesi uzak oturumda da Wi-Fi yolundaki gibi görünür/çalışır (istemci STANDBY bildirdiyse).
2. **Tavan:** `link = 1` iken H→C dosya gönderim kovası sabit **500 000 B/s** (normalde `FilesRateCap.capBytesPerSec(videoKbps:)`). Küçük şerit aynı. `link` ya da bit hızı oturum içinde değişince kova hızı güncellenir (bugün bit hızı değişince nasıl güncelleniyorsa).
3. Dosya bağlantıları kontrol bağlantısının eş adresinden (Tailscale `100.x`) gelir; dinleyici ve `FILES_HELLO` doğrulaması bunu kabul etmeli. Eşleşme yasağı (T-338) ve dosya güvenlik kuralları değişmez.
4. Log: tavan uygulandığında mevcut dosya log satırlarına uygun kısa bir alan (ör. `files_cap_bps=`), LOGGING.md'ye ekle.

## Kabul

- Birim testleri: `link = 1` → tavan 500 000 (bit hızından bağımsız); `link = 0` → eski formül bit bit aynı; link değişimi kovayı günceller; uzak oturumda `FILES_NET OPEN` gönderilebilir.
- USB ve normal Wi-Fi davranışı değişmez.
- `./scripts/check.sh` geçer. Codex incelemesi orkestratörde.

## Plan

## Handoff

## Açık sorular
