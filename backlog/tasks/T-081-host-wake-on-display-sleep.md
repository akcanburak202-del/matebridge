---
id: T-081
title: Mac — tablet bağlıyken ekran uykusunda görüntü koparsa ekranı uyandır (IOPMAssertionDeclareUserActivity)
status: review
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

- **Commit:** `3889378` (uygulama), plan `d296e48`; dal `task/T-081-host-wake`. `./scripts/check.sh` → ALL OK (MateBridgeCoreTests 170 test, `DisplayWakePolicyTests` 10 yeni test).
- **Dokunulan dosyalar:**
  - `host-mac/Sources/MateBridgeCore/Video/DisplayWakePolicy.swift` (yeni, saf mantık)
  - `host-mac/Sources/MateBridgeHost/Video/DisplayWaker.swift` (yeni, IOKit sarmalayıcı + hata sınıflandırması)
  - `host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift` (bağlama)
  - `host-mac/Tests/MateBridgeCoreTests/Video/DisplayWakePolicyTests.swift` (yeni)
- **Varsayımlar:**
  - "Kabul edilmiş oturum" = `StreamCoordinator.session != nil`. `sessionStarted` yalnızca ACCEPTED sonrası gelir (her oturum şifreli; PAIRING onayı bekleyen bağlantı oturum başlatmaz). Tablet arka plana geçince `onStop` → BYE → `sessionEnded`, yani arka planda uyandırma yok. Grace süresindeki (oturumsuz) boru hattı hatası uyandırmaz.
  - Tetikleyiciler yalnızca: `SCStreamErrorDomain` -3815 (`noCaptureSource`; akış sırasında `didStopWithError` ya da başlatırken) ve `VirtualDisplayError.creationFailed` (`initWithDescriptor:` nil; displayID okunamazsa da aynı hata). Diğer hatalar (izin, kodlayıcı, `displayNotFound` zaman aşımı) uyandırmaz.
  - Oran sınırı oturum sonunda da korunur (hızlı oturum değişimi saniyede birden çok uyandıramaz). Log: `component=net ev=wake_display reason=capture_source_lost|display_create_nil wakes=N` — bölümün ilk uyandırması, neden değişimi ya da 10 s'de bir; IOKit hata verirse `ev=wake_display_failed iokit=0x…` (her denemede, en çok 1/s).
  - `IOPMAssertionDeclareUserActivity` dönen id saklanıp sonraki çağrıya veriliyor (başlık önerisi); `IOPMAssertionRelease` çağrılmıyor — başlık bu çağrının ekran uykusunu yalnızca kullanıcının ekran uykusu ayarına kadar ertelediğini söylüyor (`caffeinate -u` ile aynı tür). `PreventUserIdleDisplaySleep` eklenmedi; `InputController`'daki `beginActivity` dokunulmadı.
  - Uyandırma `onPipelineFailed`'da 1 s'lik `pipeline_retry` beklemesinden **önce** yapılıyor, böylece yeniden deneme uyanmış ekranı buluyor. Sonraki denemeler mevcut yoldan (istemcinin video yeniden bağlanması → `onVideoAttached` → `createPipeline`) gelir; başarısız her oluşturma 1/s sınırıyla tekrar uyandırır.
- **Test edilmeyenler / cihazda doğrulanacaklar:**
  - Host uygulaması çalıştırılmadı, `bundle-host.sh` çalıştırılmadı, gerçek ekran uykusu denenmedi (talimat gereği). Doğrulanacak: oturum açıkken `pmset displaysleepnow` → log'da `pipeline_failed … -3815` ardından `ev=wake_display reason=capture_source_lost wakes=1`, ~1 s içinde `pipeline_retry` → `display_created` → `video_streaming`; tablette (kilit açıksa) kilit ekranı görünmeli.
  - Hata `-3815`'in gerçekten `SCStreamErrorDomain` alanında geldiği (NSError köprüsü) cihazda log'dan teyit edilmeli; farklı bir alan/kodla gelirse uyandırma tetiklenmez (log'da `wake_display` görünmez).
  - Tablet bağlı değilken / arka plandayken `pmset displaysleepnow` → `wake_display` **olmamalı**, Mac normal uyumalı.
  - Uyanınca ekran, kullanıcının ekran uykusu süresi kadar sonra tekrar uyuyabilir; bu sırada akış yine -3815 ile düşüp tekrar uyandırılır mı (yani pratikte "oturum boyunca uyanık" gibi davranır mı) gözlenmeli. Kabul kriterine göre bu beklenen davranış (uyku nedenli kopma → uyandırma), ama kullanıcı oturum açıkken ekran uykusunu hiç görmeyecekse bu NOTES'a yazılmalı.
- **Açık sorular:**
  - Yukarıdaki son madde: tablet oturumu aktif ve sanal ekran uykuya girince host hemen uyandırdığı için, oturum boyunca kilit (uykuyla tetiklenen) pratikte hiç devreye girmeyebilir. Kart bunu istiyor ("tablette MateBridge açık ve oturum aktifken host ekranı uyandırsın"), T-040'taki "oturum boyunca uyanık tutmak varsayılan değil" maddesiyle gerilimi kullanıcıya/orkestratöre not ediyorum.
  - `VirtualDisplayError.creationFailed` başka nedenlerle de (ör. aynı seri numaralı ekran henüz kaldırılmamışken) gelebilir; o durumda gereksiz ama 1/s sınırlı bir uyandırma olur.
