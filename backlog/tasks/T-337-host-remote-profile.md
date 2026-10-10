---
id: T-337
title: Host — 0038 protokol kodu (STREAM_PREFS link/fps/taban, AUDIO_* ayrıştırma) ve uzak profil davranışı
status: todo
phase: 7
owner: mac-host-dev
depends_on: [T-336]
decisions: [0038]
files:
  - host-mac/Sources/MateBridgeCore/
  - host-mac/Sources/MateBridgeHost/Session/
  - host-mac/Sources/MateBridgeHost/Video/
  - host-mac/Sources/MateBridgeHost/Cursor/
  - host-mac/Sources/MateBridgeHost/Files/
  - host-mac/Tests/
  - docs/KNOBS.md
  - backlog/tasks/T-337-host-remote-profile.md
---

## Amaç

Karar 0038 §3 ve PROTOCOL.md'deki yeni kuralların host tarafı. Dal tabanı: `task/0038-remote-integration` (main değil).

## Kapsam

1. **Protokol kodu (Swift):**
   - STREAM_PREFS: fps `15`/`30` desteklenir; kullanıcı bit hızı aralığı `500`–`150000` (`StreamPrefsPolicy`, `VideoSettings` env knob, `BitrateRequest.defaultRange` birlikte); üçüncü isteğe bağlı grup `link` + `reserved` (16 bayt; 15 bayt protokol hatası).
   - AUDIO_PREFS `codec` alanı (ayrıştırma + kodlama), AUDIO_CONFIG `format = 2` sabiti, AUDIO_FRAME `frame_count` sınırı 1–1024, HELLO bit14 `AUDIO_AAC` sabiti. **AAC kodlama bu kartta yok** (T-340); host bu kartta her zaman PCM gönderir.
   - Yeni fixture'ların hepsi için decode/encode testleri (`everyFixtureFileHasATestCase` geçmeli).
2. **15/30 fps:** sanal ekran 60 Hz kalır; `FrameGate` ve yakalama aralığı bu hızlarda doğru seyreltir. Varsayılan bit hızı formülü (`defaultBitrateKbps`) düşük fps'te taban 20 Mbps'e takılmamalı mı? Uzak profil her zaman bit hızı gönderdiği için formül değişmeyebilir; karar planda gerekçeyle yazılsın.
3. **`link = 1` davranışı (oturum başına, son STREAM_PREFS):**
   - host kontrol PING'i 2 sn; heartbeat kapanışı 15 sn; 1,5 sn release-all **değişmez**;
   - `CURSOR_STATE` canlılık aralığı 2 sn;
   - netleştirme treni bütçesi ve video soketi düşük su işareti = hedef bit hızının 250 ms'si, en az 16 KB;
   - `FILES_NET OPEN` gönderilmez (açıksa kapatılır);
   - tercih T-049 cihaz deposuna yazılmaz.
4. Loglar: `ev=stream_prefs ... link=1` gibi tek satır; LOGGING.md biçimi.

## Güvenlik kuralı (AGENTS.md)

Heartbeat değişikliği takılı girdi yaratmamalı: release-all 1,5 sn'de kalır. Testle doğrula: `link = 1` iken 1,5 sn sessizlikte tutulan tuş bırakılır, bağlantı 15 sn'ye kadar açık kalır.

## Kabul

- `./scripts/check.sh` Swift kısmı geçer (Kotlin kısmı T-339'a kadar fixture kapsamında düşebilir; handoff'ta yaz).
- Birim testleri: STREAM_PREFS 8/12/14/16 bayt ve 15 bayt hatası; fps 15/30 kabul, 45 → 60; bit hızı 400 → 500, 1000 → 1000; link=1 zamanlamaları; T-049 deposuna yazılmaz; FILES_NET OPEN bastırılır.
- Cihaz testi orkestratörde (uzak oturum, T-339 ile birlikte).

## Plan

## Handoff

## Open questions
