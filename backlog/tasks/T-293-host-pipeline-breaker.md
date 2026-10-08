---
id: T-293
title: Host — kalıcı medya hatasında devre kesici (video bağlanınca bütçeye sor, bekleme 10/20/30 sn, aynı cihazın oturumunda sıfırlama yok)
status: review
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

1. `PipelineRetryPolicy`: `PipelineFailureKind.start`; kesici durumu (`openUntilUs`, `probing`, `level`), `admit`, `built`, `stopped`, `sessionStarted(device:)`, `reset()`, `breaker` anlık görüntüsü (log için), `refusals` sayacı. Mevcut 60 sn / 3 deneme / 1-2-4 sn ve `.fallBackToSDR` aynen.
2. `StreamCoordinator`: `onVideoAttached` `admit` sorar, `refuse` ise log + `link.cancel()`; `createPipeline` başarıda `built`, tüm geri düşüşlerden sonra hâlâ hatada `.start` kaydı; sıfırlama olayları; loglar.
3. Saf politika testleri `PipelineBreakerTests.swift` (yeni dosya, `Tests/.../Video/` altında).

## Handoff

Commit: `git log task/T-293-pipeline-breaker` (tek commit `T-293: ...`).

Dosyalar: `host-mac/Sources/MateBridgeCore/Video/PipelineRetryPolicy.swift`, `host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift`, `host-mac/Tests/MateBridgeCoreTests/Video/PipelineBreakerTests.swift` (yeni), bu kart.

Davranış:
- `.giveUp` (4. hata ya da başarısız deneme kurulumu) kesiciyi açar: 10 -> 20 -> 30 sn (tavan 30). `admit` süre dolana kadar `.refuse(remaining)`; süre dolunca ilk `admit` durumu `probe` yapar ve `.build` döner. Probe sırasında gelen her hata (çalışırken ya da `.start`) `.giveUp` döner ve bir sonraki basamağı açar (60 sn pencereye bakmadan, zamanlayıcı yok). Açılışta `failures` silinmez, böylece mevcut 3 deneme / 60 sn davranışı değişmez.
- Tembel başarı: `failed` (`.start` hariç) ve `stopped` (park, `restartPipeline`, `destroyPipeline`) pipeline >= 10 sn ayaktaysa geçmişi, basamağı ve kesiciyi temizler. `built(now)` `createPipeline` başarısında çağrılır.
- `.start` hatası yalnız `createPipeline`'ın HDR / packed / oyun ekranı geri düşüşlerinin hiçbiri uygulanmadığında kaydedilir (`fallBackFromGameDisplay` artık Bool döner). Dönen `Decision` yok sayılır (zamanlayıcı yok; yeniden deneme istemcinin video bağlantısıyla gelir ve `admit`'ten geçer). Yani ilk 3 başlatma hatası serbest, 4. hata kesiciyi açar.
- Sıfırlama olayları: (a) başka cihaz: `onSessionStarted` -> `retryPolicy.sessionStarted(device:)`; aynı cihazda sıfırlama YOK (eski koşulsuz `reset()` kaldırıldı); (b) Mac uyanması: `onPower(.didWake)` yeni `.macWoke` mailbox olayı (coalesced, key 5) -> `reset()`; (c) `applyPrefs` içinde `wanted != live.settings` (pipeline'ı değiştiren her STREAM_PREFS / mod değişikliği) -> `reset()`. Host'un kendi geri düşüşleri (HDR/SDR, packed, oyun ekranı) kullanıcı değişikliği sayılmadı; SDR geri düşüşü politikayı zaten temizliyor.
- Loglar: `pipeline_breaker state=open|probe|closed wait_ms= level=` (durum ya da basamak değişince; open `warning`), `pipeline_rebuild_refused remaining_ms= level= n=` (ilk ve her 10. ret, `warning`), ek olarak `pipeline_breaker_reset reason=mac_wake|prefs_change` (kesici kapalı değilken). `docs/LOGGING.md` kart dosya listesinde olmadığı için güncellenmedi; orkestratör eklemeli (`pipeline_retry_exhausted` satırındaki "tablet yeniden bağlanınca yine kurulur" notu da artık geçersiz).
- `closed` logu tembeldir: kesici ancak sonraki hata / durdurma / sıfırlamada kapanır (zamanlayıcı yok).

check.sh: ALL OK. Yalnız birim testi çalıştırıldı (21 yeni saf kesici testi); host, tablet, GUI kullanılmadı.

Gerçek cihazda doğrulanacak: kalıcı kodlayıcı hatasında 4 kurulum sonrası ret döngüsü (T-294 olmadan tablet her 500 ms bağlanıp kapatılır, ret ucuz); probe başarısında görüntünün kendiliğinden dönmesi (T-294 manual_resume ile); uyku/uyanma sınırında `did_wake` sıfırlaması; `onVideoAttached` ret yolunda sanal ekranın yaratılmadığı.

## Open questions
