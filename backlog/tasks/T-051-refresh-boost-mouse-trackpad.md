---
id: T-051
title: Touchpad/fare ile sürüklerken fps ~68–70, kalemle ~120 — Huawei 120 Hz yükseltmesini fare/touchpad için de sağlamak
status: done
phase: 5
owner: orchestrator
depends_on: [T-049, T-050]
decisions: []
files:
  - docs/NOTES.md
  - backlog/tasks/T-051-refresh-boost-mouse-trackpad.md
---

## Amaç

Kullanıcı gözlemi (2026-10-01, host 120 fps): istatistik katmanında touchpad ya da Bluetooth fare ile pencere sürüklerken **fps ~68–70**, kalemle sürüklerken **~120**. Kullanıcı: "bu soruyu sıraya al", performans modu (T-049/T-050) bittikten sonra.

## Bilinenler

- NOTES 2026-10-01: Huawei `FrameRateManager` bizim paket için `idle 60`; dokunma (touchinfo) sırasında 120 Hz. Kalem dokunma sayılıyor; pointer capture altındaki touchpad/fare olayları büyük olasılıkla sayılmıyor → panel 60 Hz, çözücü/gösterim ~60–70.

## Yapılacaklar (sonra)

- [ ] Ölç: touchpad/fare sırasında `display_hz`, AGPService `touchinfo` satırları.
- [ ] Seçenekleri araştır: capture olaylarının sisteme "dokunma etkinliği" olarak yansıtılması (ör. görünüm üzerinde `View.setFrameContentVelocity`/`setRequestedFrameRate` (API 35), `Window.setFrameRateBoostOnTouchEnabled`, HarmonyOS'a özgü sahne ipuçları), pointer capture yerine başka bir girdi yolu, ya da kabul edilecek sınır.
- [ ] Sonuç NOTES'a; gerekiyorsa android-client-dev kartı.

## Plan

_(Orkestratör, T-049/T-050 bitince.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**

## Sonuç (2026-10-01)

Ölçüldü (NOTES 01:07): Performans modunda ve tablet "Dinamik"ken touchpad/fare sürüklemesinde panel 120 Hz, 105–117 fps; kalemle 120 fps. Sorun, tam boyutlu modda çözücü sınırı ve "Orta" ayarıydı. Kod değişikliği gerekmedi.
