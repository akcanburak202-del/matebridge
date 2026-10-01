---
id: T-081
title: Mac — tablet bağlıyken ekran uykusunda görüntü koparsa ekranı uyandır (IOPMAssertionDeclareUserActivity)
status: in-progress
phase: 4
owner: mac-host-dev
depends_on: [T-040]
decisions: []
files:
  - host-mac/Sources/MateBridgeHost/
  - host-mac/Sources/MateBridgeCore/
  - host-mac/Tests/
  - backlog/tasks/T-081-host-wake-on-display-sleep.md
---

## Amaç

T-040 ölçümü (NOTES 2026-10-01 ~14:10): ekran uykusunda SCStream **-3815** → `pipeline_retry` → `CGVirtualDisplay initWithDescriptor: returned nil` her ~0,6 s; tablet "Gelen kare: 0" panelinde girdi göndermediği için Mac'i uyandıramıyor, kullanıcı mahsur kalıyor. `caffeinate -u` (kullanıcı etkinliği) anında sanal ekranı geri getirdi, kilit ekranı tablette göründü.

Kullanıcı kararı (2026-10-01): tablette MateBridge açık ve oturum aktifken host ekranı uyandırsın. Kilit güvenliği değişmez (kilit uykuda devreye girer, uyanınca kilit ekranı görünür). Tablet oturumu kapanınca normal uyku.

## Kabul kriterleri

- [ ] Kabul edilmiş (şifreli, PAIRED) bir tablet oturumu varken video hattı ekran yokluğu/uyku nedeniyle düşerse (SCStream -3815 ya da sanal ekran oluşturma `nil`), host `IOPMAssertionDeclareUserActivity(kIOPMUserActiveLocal)` çağırır — en çok saniyede bir, yalnızca bu hata durumunda (sürekli değil); yeniden deneme mevcut mantıkla sürer. Log: `ev=wake_display reason=… ` (değişimde/oran sınırlı).
- [ ] Oturum yokken (tablet arka planda / bağlı değil) hiçbir uyandırma yapılmaz. Onay bekleyen (PAIRING) ya da şifresiz oturum uyandırma tetiklemez.
- [ ] Ekranı sürekli uyanık tutan bir assertion **eklenmez** (`PreventUserIdleDisplaySleep` yok); mevcut `PreventUserIdleSystemSleep` davranışı değişmez.
- [ ] Saf mantık (ne zaman uyandırılır, oran sınırı) testli; IOKit çağrısı ince bir sarmalayıcıda.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

1. `MateBridgeCore/Video/DisplayWakePolicy.swift` (saf): `DisplayWakeReason` (`capture_source_lost` = SCStream -3815, `display_create_nil` = sanal ekran `nil`), SCK hata kodu sınıflandırması, `DisplayWakePolicy.displayLost(reason:sessionActive:now:)` → `.skip` / `.wake(log:)`: oturum yoksa ya da neden tanınmıyorsa asla uyandırmaz; en çok 1 uyandırma/s; log yalnızca bölümün ilk uyandırmasında, neden değişince ya da bölüm içinde 10 s'de bir (`wakes=N`). `recovered()` (ekran oluşturuldu) ve `sessionEnded()` bölümü sıfırlar.
2. `MateBridgeHost/Video/DisplayWaker.swift`: `IOPMAssertionDeclareUserActivity(kIOPMUserActiveLocal)` ince sarmalayıcı; dönen assertion id saklanıp sonraki çağrıya verilir (başlık dosyasının önerisi; ekran uykusu ayarına kadar erteleme, kalıcı assertion değil). `PreventUserIdleDisplaySleep` yok. Hata sınıflandırması (VirtualDisplayError.creationFailed, SCStreamErrorDomain -3815) burada.
3. `StreamCoordinator`: `pipelineFailed` olayına sınıflandırılmış neden eklenir; `onPipelineFailed` ve `createPipeline` hata yolunda politika sorulur (`session != nil` = kabul edilmiş şifreli oturum; PAIRING onayı bekleyen bağlantı `sessionStarted` üretmez, tablet arka plana geçince BYE → `sessionEnded`). `display_created`'de `recovered()`, `onSessionEnded`/`onShutdown`'da `sessionEnded()`. Yeniden deneme mantığı değişmez. Log: `component=net ev=wake_display reason=… wakes=N`.
4. Testler: `Tests/MateBridgeCoreTests/Video/DisplayWakePolicyTests.swift`.

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
