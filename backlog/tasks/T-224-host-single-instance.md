---
id: T-224
title: Host — only one MateBridge instance may run (second instance exits)
status: todo
phase: 6
owner: mac-host-dev
depends_on: [T-148]
decisions: []
files:
  - host-mac/Resources/Info.plist
  - host-mac/Sources/MateBridgeApp/main.swift
  - host-mac/Sources/MateBridgeApp/LoginItem.swift
  - host-mac/Sources/MateBridgeCore/Session/SingleInstancePolicy.swift
  - host-mac/Tests/MateBridgeCoreTests/Session/
  - docs/LOGGING.md
  - backlog/tasks/T-224-host-single-instance.md
---

## Amaç

Cihaz 2026-10-04 ~12:15: Mac menü çubuğunda iki MateBridge simgesi. İki süreç (`build/MateBridge.app`), ikisi de 10:49:25'te başlamış (orkestratörün `quit` + `open --env MATEBRIDGE_LAT_TRACE=1` yeniden başlatmasıyla aynı an). Biri 47001/47002'yi, ikincisi port düşüşüyle rastgele 61082/61083'ü dinliyordu — Bonjour'da ikinci bir hizmet olarak görünebilir ve Wi-Fi'de tablet yanlış kopyaya bağlanabilir; iki USB izleyicisi, iki menü. İkinci süreç elle öldürüldü.

## Bağlam

- Olası nedenler (ajan doğrular): (a) `open` ile açılan kopya + açılışta `SMAppService.mainApp.register()` (T-148 her açılışta kayıt yeniden denemesi) launchd'ye uygulamayı bir kez daha başlattırıyor olabilir; (b) Info.plist'te `LSMultipleInstancesProhibited` yok, `open --env` ve login item birlikte iki kopya açabilir.
- İstenen: tek kopya garantisi. Info.plist `LSMultipleInstancesProhibited = true` ve açılışta, aynı bundle id'li başka bir çalışan süreç varsa (`NSRunningApplication.runningApplications(withBundleIdentifier:)`, kendisi hariç) yeni kopya **dinleyici açmadan, ekran kurmadan** loglayıp çıkar (`ev=second_instance action=exit`). Karar saf bir Core fonksiyonunda (test edilir).
- Ayrıca T-148'in kayıt yolunun yeni bir kopya başlatıp başlatmadığı doğrulanır; başlatıyorsa kayıt ancak gerektiğinde yapılır.

## Kabul kriterleri

- [ ] [XCTest] `SingleInstancePolicy`: başka kopya varken → çık; yalnızken → devam; kendi pid'i sayılmaz.
- [ ] [device] `quit` + `open` ve login-item kayıt yolu sonrasında `pgrep -x MateBridgeApp` tek süreç; menü çubuğunda tek simge; 47001/47002 dinleniyor.
- [ ] [device] Elle ikinci `open -n build/MateBridge.app` → ikinci kopya `second_instance action=exit` loglayıp çıkar, mevcut oturum etkilenmez.

## Plan

**Kod okuma sonucu (nedenin doğrulanması, uygulama çalıştırılmadı):**
- (a) T-148 kayıt yolu ikinci kopya başlatmaz. `LoginItemPolicy.action(for: .launch)` yalnızca `loginItemFirstRunDone` yokken ve durum `enabled/requiresApproval` değilken `register` çağırır; başarıyla bitince bayrak yazılır, sonraki açılışlarda hiç çağrılmaz. `SMAppService.mainApp.register()` ayrıca uygulamayı hemen başlatmaz, yalnızca giriş öğesini kaydeder (başlatma bir sonraki oturum açılışında olur). Depoda KeepAlive'lı bir LaunchAgent de yok (T-202 hâlâ todo). Yani kayıt yolunda değişiklik gerekmez; `LoginItem.swift` içinde kod değişikliği yapılmaz (dosya kapsamda kaldı, dokunulmadı).
- (b) En olası neden: `quit` + `open` yarışı, ya da iki `open` (`-n` dahil) aynı anda. Info.plist'te `LSMultipleInstancesProhibited` yoktu ve uygulama içinde hiçbir bekçi yoktu. Port düşüşü (61082/61083) ikinci kopyanın 47001/47002'yi alamadığını gösteriyor, yani ikisi de gerçekten yaşıyordu.

**Tasarım:**
1. `MateBridgeCore/Session/SingleInstancePolicy.swift` (saf): `Instance { pid, launchDate?, isTerminated }` ve `decide(ownPID:, ownLaunchDate:, others:, waitedMs:) -> Decision` (`proceed`, `wait(ms:)`, `exit(existingPID:)`).
   - Kendi pid'i ve `isTerminated` olanlar sayılmaz.
   - Engelleyen kopya yalnızca *daha eski* olandır (launchDate küçük; eşit ya da bilinmiyorsa küçük pid). Böylece aynı anda başlayan iki kopya birbirini öldürmez: yalnızca yeni olan çıkar, eski devam eder.
   - Engelleyen varsa ve `waitedMs < graceMs (5000)`: `wait(200)`. Neden: `quit` + hemen `open`'da eski kopya kapanırken yeni kopya hemen çıkarsa hiç kopya kalmaz. Süre dolunca `exit`.
2. `main.swift`: `applicationDidFinishLaunching` en başında `app_start` satırından sonra, durum çubuğu simgesi/dinleyici/ekrandan önce bekçi çalışır. `NSRunningApplication.runningApplications(withBundleIdentifier:)` ile liste kurulur, politika döngüsü ana iş parçacığında kısa uyumalarla yürütülür, `exit` kararında `ev=second_instance action=exit` loglanıp `exit(0)`. `bundleIdentifier` yoksa (`swift run`) bekçi atlanır. CLI kipleri (`--dump-video` vb.) NSApplication'dan önce çıktığı için etkilenmez.
3. `Info.plist`: `LSMultipleInstancesProhibited = true` (LaunchServices katmanı; uygulama içi bekçi `open -n` ve doğrudan çalıştırma için yedek).
4. `docs/LOGGING.md`: `ev=second_instance` satırı.
5. Testler: `Tests/MateBridgeCoreTests/Session/SingleInstancePolicyTests.swift` (başkası varken çık, yalnızken devam, kendi pid'i sayılmaz, sonlanmış sayılmaz, eşzamanlı başlangıç eski kazanır, bekleme süresi dolana kadar `wait`).

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulananlar:**
- **Açık sorular:**
