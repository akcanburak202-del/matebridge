---
id: T-299
title: Host — uyku katılımcıları hiç kayıt olmuyor; girdi ve ses uyku anında oturum kuyruğundan bağımsız bırakılsın (T-132 eksiği)
status: todo
phase: 7
owner: mac-host-dev
depends_on: []
decisions: []
files:
  - host-mac/Sources/MateBridgeHost/Input/InputController.swift
  - host-mac/Sources/MateBridgeHost/Audio/SystemAudioTap.swift
  - host-mac/Sources/MateBridgeHost/Audio/HostAudio.swift
  - host-mac/Sources/MateBridgeHost/Session/HostSleepParticipants.swift
  - host-mac/Sources/MateBridgeHost/Session/SessionServer.swift
  - host-mac/Sources/MateBridgeCore/Session/HostSleep.swift
  - host-mac/Tests/MateBridgeCoreTests/Session/
  - backlog/tasks/T-299-host-sleep-participants.md
---

## Amaç

T-297 incelemesi, bulgu B1 (`docs/reviews/2026-10-08/agents/simp-b-host-session.md`; orkestratör doğruladı). `HostSleepParticipants` (`HostSleepParticipants.swift`) tanımlı ve `SessionServer.onPower` her `will_sleep`'te `snapshot()` alıp katılımcıları bekliyor. Ama üretim kodunda hiçbir yer `register(` çağırmıyor, yani liste her zaman boş.

T-132 Handoff'u "InputController `start()`'ta `input`, SystemAudioTap `init`'te `audio` olarak kayıt olur" diyor, ama ef3f5079 bunu içermiyor (`git log -S releaseOnQueue` yalnız kart metnini buluyor). Sonuç: uyku anında girdinin release-all'u yalnız oturum kuyruğu üzerinden (`machine.hostSleep()`) yapılıyor. Kuyruk takılırsa Codex P1'in istediği yedek yol yok. `host_sleep_ack` logunda `input=`/`audio=` alanları hiç görünmüyor.

## Kabul

1. **InputController kaydı:**
   - Yaşam döngüsünün başında (`start()` ya da eşdeğeri) `HostSleepParticipants.shared.register(self, name: "input")` ile kayıt olur, durunca `unregister` eder.
   - İşi kendi girdi kuyruğunda release-all yapmak. Bu, oturum sonu yolu ile idempotenttir: çift bırakma olmaz, eksik bırakma olmaz.
   - Bitince tamamlama geri çağrısını bir kez çağırır.
2. **SystemAudioTap (ya da HostAudio) kaydı:** `audio` adıyla kayıt olur; işi kendi kuyruğunda yakalamayı kapatmak, sonra tamamlama.
3. **Log:** `host_sleep_ack` satırı `input=done|pending audio=done|pending` alanlarını taşır (`HostSleepProgress`, `HostSleep.swift`). Biçim `docs/LOGGING.md`'de belgeli değilse önerilen metni Handoff'a yaz.
4. **Sıra:** katılımcı işleri oturum kuyruğunu beklemeden başlar (`SessionServer.onPower` 1. adım). Tutulan tuş, düğme ya da kalem teması uyku boyunca Mac'te asılı kalmaz (AGENTS.md).
5. **Test:**
   - Saf kısım (`HostSleepProgress` sırası, idempotent tamamlama) için Core testi.
   - Host hedefinin test hedefi yok; kayıt ve bırakma derleme ve cihazla doğrulanır.
6. **Cihazda bakılacak (orkestratör):** `pmset sleepnow` ile uyku. Host logunda `host_sleep_ack … input=done audio=done complete=1` ve `input_release` görülmeli; uyanınca takılı girdi olmamalı.

## Plan

## Handoff

## Open questions
