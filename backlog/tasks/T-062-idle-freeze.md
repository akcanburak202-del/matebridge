---
id: T-062
title: Boşta → hareket geçişinde ve yazarken donma (son kare gönderilmiyor/bırakılmıyor)
status: done
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

Teşhis (2026-10-01 öğlen, orkestratör): ortak ilke ihlali — **en yeni kare ekrana ulaşmalı; bir kare ancak daha yeni bir kare onun yerini alırsa atılabilir.**

1. **Tablet (asıl suçlu, T-060/T-057):** faz kilidi seyrek karelerde (60 Hz, 100–600 ms aralık) slotu eski kilitten `round(dCapture/P)` ile tahmin ediyor; host 120 Hz ızgarası yüzünden yarım periyot kayınca slot `earliest`'ten önce → `lateDrop` → `SlotReleaser` bırakılmış slota düşen kareyi atıyor; ardıl yok. Simülasyon: 126/300 kare hiç gösterilmedi (60 Hz, 100–600 ms); > 1 s boşlukta yeniden çapalama sayesinde 0. Kilit 30 kare yanlış kalıyor → imleç hareketinin başında takılma. → **T-065**.
2. **Host (T-058, şu an çalışan `bdf52f0`'da yok):** seyreltmede ızgaradan erken gelen kare tutulmuyor, atılıyor → son değişiklik gönderilmeyebilir. → **T-066**.
3. Eski yapılarda da olan nadir "uzun beklemeden sonra ilk tuş" ayrı; T-065/T-066 sonrası seyrek güncelleme düzeneğiyle (Mac'te tek kare değişikliği, tablette `screencap` piksel kontrolü) ölçülecek.

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**

## Sabah durumu (2026-10-01)

- Geri alma (tablet 98b325e, host bdf52f0) donmayı ve imleç takılmasını giderdi → T-057/T-060/T-061 sunum değişiklikleri tek kare/boşta durumunda bozuk; bunlar yeniden ele alınmalı (test: boşta tek tuş, imleç tek adım, `anim` dışında).
- Kalan nadir sorun: uzun beklemeden sonra ilk tuşun karesi bir sonraki değişikliğe kadar görünmüyor (eski yapılarda da var).

## Sonuç (2026-10-01)

T-065 + T-066 ile çözüldü; kullanıcı doğruladı (harfler hemen görünüyor, imleç takılması yok). Nadir "uzun beklemeden sonraki ilk tuş" da ölçümde (2–4 s bekleme sonrası tek değişiklik 6/6) görülmedi.
