---
id: T-332
title: İstemci — sabit ekranda/girdi yokken inputTicker ve PING seyreltme (pil)
status: todo
phase: 7
owner: android-client-dev
depends_on: [T-330]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/WifiKnobs.kt
  - client-android/app/src/test/
  - backlog/tasks/T-332-client-idle-ticker-gating.md
---

## Amaç

`docs/research/2026-10-10-optimization.md` A1:
- `inputTicker` 25 ms'de bir dönüyor (`MainActivity.kt:1130`, `INPUT_TICK_MS`). Ekran sabitken ve hiçbir girdi tutulmazken de saniyede 40 uyanma yapıyor.
- PING 500 ms'de bir gidiyor.
- Bağlıyken wol ve auto ticker'ları da dönüyor.

## Güvenlik kuralı (AGENTS.md)

Takılı girdi olmamalı.
- Herhangi bir tuş, düğme ya da kalem teması tutuluyorsa veya aktif bir işaretçi varsa tik **25 ms'de kalır**.
- `inputFailed` ve `capture.tick` bırakma yolu yavaşlatılmaz.
- İlk MotionEvent ya da KeyEvent hızlı tiki **hemen** geri açar.

## Kapsam (öneri; plan yazılırken netleşsin)

1. Girdi boştayken tik 100 ms'ye çıkar. `idle.tick` ve `cursorStep` bu hızda yeterli mi, kontrol edilsin; T-276 imleç tahmini etkilenmemeli.
2. Bağlıyken wol ve auto ticker'ları durur.
3. Ekran 2 sn'den uzun sabitse PING 1000 ms'ye çıkar. PONG zaman aşımı 3 sn'de kalır. Bu değişiklik bir knob arkasında, varsayılan olarak kapalı başlar.

## Kabul

- Birim testleri iki şeyi doğrular: girdi tutulurken tik hızlı kalır; ilk olayda hızlı tike dönülür.
- `./scripts/check.sh` geçer.
- Cihaz testini orkestratör yapar, T-320 pil koluyla birlikte:
  - sabit ekranda 10'ar dakikalık ABAB;
  - tablet CPU'su, uyanmalar ve şarj sayacı karşılaştırılır;
  - ilk dokunma gecikmesi ölçülür.

## Plan

## Handoff

## Open questions
