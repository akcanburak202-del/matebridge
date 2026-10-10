---
id: T-340
title: Host — AAC-LC ses kodlama (AUDIO_PREFS.codec = 1 ve HELLO bit14)
status: todo
phase: 7
owner: mac-host-dev
depends_on: [T-337]
decisions: [0038, 0011]
files:
  - host-mac/Sources/MateBridgeCore/Audio/
  - host-mac/Sources/MateBridgeHost/Audio/
  - host-mac/Tests/
  - backlog/tasks/T-340-host-aac-audio.md
---

## Amaç

Karar 0038 §4; PROTOCOL.md AUDIO_PREFS/CONFIG/FRAME. Dal tabanı: `task/0038-remote-integration` (T-337 birleştikten sonra).

## Kapsam

1. Bit14 + `codec = 1` iken `AudioConverter` ile AAC-LC 48 kHz stereo, 96 kbps; her `AUDIO_FRAME` bir ham erişim birimi (ADTS yok), `frame_count = 1024`, `AUDIO_CONFIG.format = 2`, `frames_per_packet = 1024`. Aksi halde bugünkü PCM.
2. Kodlama gerçek zamanlı IOProc'ta **değil**; `AudioStreamer` kuyruğunda ya da ayrı bir aşamada. Kuyruk sınırları (§5, 100 ms) korunur.
3. `sample_index`/`capture_time_us`: biriminin çözülünce verdiği ilk kareye ait; kodlayıcı gecikmesi (priming) düşülür; birimler arası +1024.
4. Kodek değişimi (codec 0↔1) yeni `stream_id` ile akışı yeniden başlatır. Sessizlik kapısı (T-279) AAC'de de çalışır.
5. Kodlayıcı kurulamazsa PCM'e düşer ve bir kez loglar.

## Kabul

- Birim testleri: kodek seçimi (bit14 yok → PCM; codec 0 → PCM); erişim birimi zaman damgası aritmetiği; kodek değişiminde stream_id artar.
- Gerçek `AudioConverter` ile bir sinüs kodla → AU boyları 1–1536 arasında, ortalama ~96 kbps.
- `./scripts/check.sh` geçer. Codex incelemesi (orta).

## Plan

## Handoff

## Open questions
