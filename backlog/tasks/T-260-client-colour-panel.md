---
id: T-260
title: Client panel — "Renk: Normal / Keskin kenarlar / Tam renk" (decision 0034), migrate the 0033 setting
status: ready
phase: 6
owner: android-client-dev
depends_on: [T-259]
decisions: [0034, 0033]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/settings/
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/
  - client-android/app/src/test/kotlin/dev/matebridge/client/
  - backlog/tasks/T-260-client-colour-panel.md
---

## Amaç

Karar 0034 §2: panelde "Keskin renk kenarları" (Kapalı/Açık) satırı **"Renk"** olur: **Normal / Keskin kenarlar / Tam renk**, varsayılan Normal, kalıcı. Kayıtlı 0033 değeri taşınır (Açık → Keskin kenarlar). T-259'un dalı üzerine kur.

## Bağlam

- "Tam renk" yalnız Günlük 60'ta uygulanır; diğer modlarda satır notu "Tam renk yalnız Günlük 60'ta, şimdi: Keskin kenarlar". `FullChromaCapability` (T-259) yoksa seçenek gri "Bu cihazda yok". HDR10 uygulanırken bugünkü gri not aynen.
- Uygulanan durum notu: host `chroma_layout = 1` bildirdiyse "Uygulanan: Tam renk", geri düştüyse "Uygulanan: Normal (Mac yetişemedi)".
- Sözcükler panelde Türkçe; kod İngilizce.

## Kabul kriterleri

- [ ] Taşıma + seçenek mantığı birim testli; `./scripts/check.sh` geçer.

## Plan

## Handoff

## Open questions
