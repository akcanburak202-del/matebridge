---
id: T-293
title: Host — kalıcı medya hatasında devre kesici (video bağlanınca bütçeye sor, bekleme 10/20/30 sn, aynı cihazın oturumunda sıfırlama yok)
status: todo
phase: 6
owner: mac-host-dev
depends_on: [T-291]
decisions: [0019]
files:
  - host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift
  - host-mac/Sources/MateBridgeCore/Video/PipelineRetryPolicy.swift
  - host-mac/Tests/MateBridgeCoreTests/Video/
  - backlog/tasks/T-293-host-pipeline-breaker.md
---

## Amaç

T-291 tasarım notu, "Host: devre kesici" bölümü (`backlog/tasks/T-291-rebuild-budget-with-client-ladder.md`). Kalıcı kodlayıcı ya da yakalama hatasında host, tablet her video bağlantısı açtığında (500 ms) pipeline'ı ve sanal ekranı yeniden kuruyor. Bütçe de tabletin +6 sn oturum yenilemesiyle sıfırlanıyor. Cihazda görülmedi.

## Kabul

1. `PipelineRetryPolicy` (saf, `MateBridgeCore`) şunları kazanır:
   - açık durum ve bekleme basamağı (10 → 20 → 30 sn, tavan 30 sn);
   - `admit(nowUs) -> .build | .refuse(remainingUs)`;
   - `.start` hata türü;
   - tembel başarı: hata anında pipeline ≥ 10 sn ayaktaysa önce geçmiş ve basamak temizlenir. Bunun için politika kurulum zamanını alır (ör. `built(nowUs)`).
   Mevcut 60 sn / 3 deneme / 1-2-4 sn ve `.fallBackToSDR` davranışı değişmez.
2. `onVideoAttached`, pipeline yoksa kurmadan önce `admit` sorar. `refuse` olursa bağlantıyı hemen kapatır: ekran, yakalama ya da kodlayıcı kurulmaz. Zamanlayıcı ya da bekletme yoktur.
3. `createPipeline` kendi geri düşüşlerinden sonra yine başarısızsa hata `.start` olarak kaydedilir.
4. Sıfırlama:
   - aynı cihazın yeni oturumunda **yok**;
   - başka cihazda (devralma) var;
   - Mac uyanınca var (mevcut uyanma olayı);
   - pipeline'ı değiştiren STREAM_PREFS ya da mod değişikliğinde var.
   Hangi olayları kullandığını Handoff'ta yaz.
5. Loglar (`docs/LOGGING.md` biçimi):
   - `pipeline_breaker state=open|probe|closed wait_ms= level=`;
   - `pipeline_rebuild_refused remaining_ms= level= n=` (ilk ret ve her 10. ret).
6. Birim testleri (saf politika):
   - açılma ve bekleme basamakları;
   - süre dolunca bir deneme kurulumu (`probe`), başarısızsa sonraki basamak;
   - tembel başarı temizliği;
   - `.start` sayımı;
   - aynı cihaz/başka cihaz sıfırlama kuralı (politika düzeyinde ne test edilebiliyorsa);
   - `.fallBackToSDR` regresyonu.
7. Kapsam dışı: `onPipelineFailed` içindeki bloklayan geri çekilme beklemesi ve ekran ömrü (T-200).

## Plan

## Handoff

## Open questions
