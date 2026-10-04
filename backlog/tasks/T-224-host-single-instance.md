---
id: T-224
title: Host — only one MateBridge instance may run (second instance exits)
status: review
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

- [x] [XCTest] `SingleInstancePolicy`: başka kopya varken → çık; yalnızken → devam; kendi pid'i sayılmaz.
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

- **Commit:** (SHA aşağıda commit sonrası yazıldı; dal `task/T-224-host-single-instance`, plan commit'i + uygulama commit'i)
- **Dokunulan dosyalar:** `host-mac/Sources/MateBridgeCore/Session/SingleInstancePolicy.swift` (yeni), `host-mac/Tests/MateBridgeCoreTests/Session/SingleInstancePolicyTests.swift` (yeni, 9 test), `host-mac/Sources/MateBridgeApp/main.swift`, `host-mac/Resources/Info.plist` (`LSMultipleInstancesProhibited`), `docs/LOGGING.md`, bu kart. `LoginItem.swift` değişmedi.
- **check.sh:** ALL OK.
- **T-148 kayıt yolu (yalnız kod okuma):** ikinci kopya başlatmaz. `register` yalnızca `loginItemFirstRunDone` yokken ve durum `enabled/requiresApproval` değilken çağrılır, başarıda bayrak yazılır; `SMAppService.mainApp.register()` uygulamayı hemen başlatmaz, yalnız giriş öğesini kaydeder. Depoda KeepAlive LaunchAgent'ı da yok (T-202 todo). Bu yüzden kayıt koduna dokunulmadı. En olası neden `quit`+`open` yarışı / çift `open`; kesin kanıt cihazda aranabilir (iki `app_start` satırı, `second_instance` ile yakalanır).
- **Varsayımlar / tasarım kararları:**
  - Kartın "başka kopya varsa çık" kuralına iki ek: (1) yalnızca *daha eski* canlı kopya engeller (launchDate, eşitse küçük pid), böylece aynı anda başlayan iki kopya birbirini öldürmez; (2) eski kopya kapanırken yeni kopya en çok 5 sn (200 ms aralıkla) bekler, çünkü `quit` + hemen `open` akışında yeni kopya hemen çıkarsa hiç kopya kalmaz. Süre dolarsa çıkar. Bekleme ana iş parçacığında, hiçbir UI/dinleyici açılmadan önce (`Thread.sleep`).
  - Bekçi `app_start` satırından sonra, simge/dinleyiciden önce çalışır; `second_instance` WARNING seviyesinde `action=exit existing_pid=<pid>`.
  - `Bundle.main.bundleIdentifier == nil` (`swift run`) ve CLI kipleri (`--dump-video` vb., NSApplication'dan önce çıkarlar) etkilenmez. Farklı `--bundle-id` ile paketlenen kopyalar birbirini engellemez.
- **Test edilmeyenler (cihaz, orkestratör):**
  - `quit` + `open` sonrası `pgrep -x MateBridgeApp` tek süreç, menü çubuğunda tek simge, 47001/47002 dinleniyor.
  - Elle `open -n build/MateBridge.app` ve doğrudan `build/MateBridge.app/Contents/MacOS/MateBridgeApp` çalıştırma: ikincisi `second_instance action=exit` loglar, mevcut oturum etkilenmez. `LSMultipleInstancesProhibited` ile LaunchServices `open -n`'i zaten engelleyebilir, o durumda log satırı çıkmaz (yalnız doğrudan exec yolunda görünür); ikisi de kabul edilebilir.
  - `quit` + hemen `open`: eski kopya kapanana kadar (<5 sn) beklenip yeni kopyanın başladığı (`app_start` sonra `listening`, `second_instance` yok). Not: `LSMultipleInstancesProhibited` açıkken LaunchServices, eski kopya ölürken `open`'ı eskiye yönlendirirse yeni süreç hiç başlamayabilir (düz `open` zaten bugün de böyle davranıyordu); gerekirse deploy betiği quit sonrası kapanmayı beklemeli (kapsam dışı, not).
- **Açık sorular:** yok (kapsam dışı dosya gerekmedi).
