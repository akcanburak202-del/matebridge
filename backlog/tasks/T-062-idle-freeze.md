---
id: T-062
title: Boşta → hareket geçişinde ve yazarken donma (son kare gönderilmiyor/bırakılmıyor)
status: todo
phase: 5
owner: orchestrator
depends_on: [T-057, T-058, T-060]
decisions: []
files:
  - docs/NOTES.md
  - backlog/tasks/
---

## Amaç

Kullanıcı geri bildirimi 2026-10-01 sabah (NOTES "kullanıcı geri bildirimi"). Ayrıntı ve hipotezler NOTES'ta; sonraki oturumda önce ölçüm/teşhis, sonra uygulama kartı.

## Plan

_(Sonraki oturum.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**

## Sabah durumu (2026-10-01)

- Geri alma (tablet 98b325e, host bdf52f0) donmayı ve imleç takılmasını giderdi → T-057/T-060/T-061 sunum değişiklikleri tek kare/boşta durumunda bozuk; bunlar yeniden ele alınmalı (test: boşta tek tuş, imleç tek adım, `anim` dışında).
- Kalan nadir sorun: uzun beklemeden sonra ilk tuşun karesi bir sonraki değişikliğe kadar görünmüyor (eski yapılarda da var).
