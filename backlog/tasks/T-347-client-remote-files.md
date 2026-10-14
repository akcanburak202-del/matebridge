---
id: T-347
title: İstemci — uzak oturumda tablet dosyaları (STANDBY), tavan 0,5 MB/s
status: todo
phase: 7
owner: android-client-dev
depends_on: []
decisions: [0035, 0038]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/
  - client-android/app/src/test/
  - docs/LOGGING.md
  - backlog/tasks/T-347-client-remote-files.md
---

## Amaç

Karar 0038 eki (2026-10-14); PROTOCOL.md §4 STREAM_PREFS "Uzak profil" ve §4 "Dosya bağlantısı" (hız tavanı). Uzak oturumda tablet dosyaları Wi-Fi'daki gibi çalışmalı.

## Kapsam

1. Uzak oturumda `FILES_INFO`'yu zorla OFF bildiren kuralı kaldır: paylaşım izinliyse Wi-Fi'daki gibi STANDBY; `FILES_NET(OPEN)` gelince sunucu, kök `MateBridge/Wi-Fi/`, dosya bağlantıları kontrol bağlantısının host adresine (uzak adres/Tailscale) açılır.
2. **Tavan:** uzak oturumda C→H dosya kovası sabit **500 000 B/s** (normalde `filesCapBytesPerSec`). Küçük şerit aynı. Oturum türü ya da bit hızı değişince kova hızı güncellenir.
3. Uzak oturumdaki ağ değişimi kuralları (0038 eki §5) dosya bağlantıları için de geçerli: ağ geri çağrıları oturumu düşürmez.
4. Panelde/ayarlarda uzak oturumda dosyalar için "kapalı" gösteren bir metin varsa güncelle.

## Kabul

- Birim testleri: uzak oturumda STANDBY gönderilir (izin varsa); tavan 500 000 (bit hızından bağımsız); normal Wi-Fi'da eski formül bit bit aynı; USB değişmez.
- `./scripts/check.sh` geçer. Codex incelemesi ve cihaz testi orkestratörde.

## Plan

1. `SessionMachine.effectiveFiles()`: uzak oturumda zorla `OFF` kuralını kaldır (STANDBY/READY normal akar; tünel planı zaten kontrol bağlantısının `ep.host`'unu kullanır = uzak adres). Eski test `filesInfoIsOffInARemoteSession` yeni davranışa çevrilir (STANDBY gider, OPEN+READY tünel planı çıkar).
2. `MainActivity.syncFiles()`: `&& !remoteSession` kaldır.
3. `filesCapBytesPerSec(videoKbps, remote = false)`: `remote` ise sabit `REMOTE_FILES_CAP_BYTES_PER_SEC = 500_000`; yoksa eski formül aynen. `FilesController.setRemote(on)` bayrağı tutar, çalışan Wi-Fi sunucusunun kovasını günceller (`setRate`); `onStreamBitrate` ve sunucu başlangıcı bayrağı kullanır. `MainActivity.setRemoteSession` bayrağı `syncFiles`'tan önce iletir. Küçük şerit DavServer'da zaten ayrı ve değişmez.
4. Ağ geri çağrıları (0038 ek §5): dosya yolu ayrı ağ geri çağrısı kullanmıyor; oturumu düşüren bir şey eklenmez (kod incelemesiyle doğrulanır).
5. Ayarlar satırı `files_remote`: metin "Uzak oturumda dosya hızı 0,5 MB/s ile sınırlıdır." (anahtar sabit).
6. Testler: WifiProfileTest (tavan), RemoteSessionMachineTest (STANDBY + tünel), SettingsCatalogTest metin. LOGGING.md `rate_cap` satırına `remote=` alanı.

## Handoff

## Açık sorular
