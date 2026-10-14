---
id: T-346
title: Host — uzak oturumda tablet dosyaları (FILES_NET OPEN), tavan 0,5 MB/s
status: done
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

1. `FilesRateCap`: `remoteBytesPerSec = 500_000`; `capBytesPerSec(videoKbps:remote:)` (remote: sabit, aksi halde eski formül birebir). `FilesRateLimiter` `remote` taşır: `init(videoKbps:remote:now:)`, `setVideoKbps`, yeni `setRemote(_:now:)`; ana kova hızı ikisinden de güncellenir. Küçük şerit aynı.
2. `TabletFilesPlanner`: `Session.remote`, `linkChanged`, `session?.remote` korumaları ve menüdeki gizleme kaldırılır (uzak oturum Wi-Fi gibi). `linkChanged` artık planner'da yok.
3. `TabletFilesBridge.deliver(.streamPrefs)`: link, `EpochCoalescer` ile `netService.setRemote` çağırır (planner'a değil); `startProxy` mevcut `remote` değerini `netService.start`'a verir.
4. `FilesNetService`: `remote` durumu, `start(..., remote:)`, `setRemote`; limiter'a iletir; kovası değişince `state=cap cap_bps= remote=` logu. Eş adres denetimi (`FilesPeer.same` ile kontrol bağlantısının eşi) zaten adres eşitliğidir, `100.x` için değişiklik gerekmez.
5. Testler: FilesRateCapTests (remote 500 000, link=0 eski formül, link değişimi kovayı günceller), RemoteLinkTests'teki üç planner testi uzak oturumda OPEN gönderilebilir olacak şekilde yeniden yazılır.
6. LOGGING.md: `cap_bps` / `remote` alanları.

## Handoff

- Commit: dalın son commit'i "T-346: remote files, 0.5 MB/s cap" (SHA orkestratöre raporlandı).
- Dosyalar: `MateBridgeCore/Files/FilesRateCap.swift`, `Files/TabletFilesPlanner.swift`, `MateBridgeHost/Files/FilesNetService.swift`, `Files/TabletFilesBridge.swift`, `Tests/.../FilesRateCapTests.swift`, `Session/RemoteLinkTests.swift`, `docs/LOGGING.md`, bu kart.
- Planner artık link'i bilmez (`linkChanged` ve `Session.remote` silindi); link yalnız hız kovasını etkiler. STREAM_PREFS -> `TabletFilesBridge.deliver` -> `FilesNetService.setRemote` (kova hemen güncellenir). Yeni oturum remote=false ile başlar, `start` mevcut değeri alır.
- Eş adres: `FilesPeer.same(peer, controlPeer)` zaten adres eşitliği; `100.x` için kod değişikliği gerekmedi. Eşleşme yasağı ve dosya güvenliği dokunulmadı.
- Log: `ev=files_net state=listening|cap ... cap_bps= remote=0|1`; `files_stats.cap_bps` zaten vardı.
- check.sh geçti. Cihazda doğrulanmadı: uzak oturumda menüden "Tablet dosyalarını aç", gerçek aktarım hızı ~0,5 MB/s, link değişiminde kova. Mac'te GUI/mount çalıştırılmadı.
- Not: uzak oturumda açık bir Wi-Fi paylaşımı link geçişinde artık kapatılmaz (paylaşım sürer, yalnız hız değişir).

## Açık sorular

### Codex turu 1 düzeltmeleri
- P2 (başlangıç yarışı): `remoteLink` anlık görüntüsü kaldırıldı. En yeni `link` `FilesNetService.desiredRemote` içinde (kilitli) durur; `start` onu kendi kuyruğunda okur, `setRemote` uygulaması aynı kuyrukta çalışır, bu yüzden eski değer yenisini ezemez.
- P2 (sınırsız kuyruk): `setRemote` en-yeni-kazanır tek bekleyen boşaltma bloğu kullanır (`linkDrainPending`); salvo kaç STREAM_PREFS getirirse getirsin en çok 1 blok bekler. Host hedefinde birim test altyapısı yok (sokete/kuyruğa bağlı); Core mantığı değişmedi.
