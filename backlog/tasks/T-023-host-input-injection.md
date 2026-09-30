---
id: T-023
title: Mac girdi enjeksiyonu — CGEvent kalem/fare, koordinat dönüşümü, oturuma bağlama
status: review
phase: 2
owner: mac-host-dev
depends_on: [T-022]
decisions: [0002]
files:
  - host-mac/Sources/MateBridgeHost/Input/
  - host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift
  - host-mac/Sources/MateBridgeCore/Input/Geometry+Display.swift
  - host-mac/Sources/MateBridgeCore/Input/   # review round: new files only (the Geometry+Display split, owed-release logic, ReleaseCause log names)
  - host-mac/Sources/MateBridgeCore/Session/SessionMachine.swift   # review round: one new ReleaseCause case (gate lost) and the switches it needs
  - host-mac/Sources/MateBridgeHost/VirtualDisplay.swift   # review round: expose the vendor and product numbers as named constants only
  - host-mac/Sources/MateBridgeApp/
  - host-mac/Tests/MateBridgeCoreTests/Input/
---

## Amaç

T-022'nin `InjectAction`'larını gerçek macOS olaylarına çevirmek ve oturumdan gelen girdi mesajlarını bağlamak.

## Kabul kriterleri

- [ ] `CGEventInjector` (Host): Faz 0'da doğrulanan yöntem (`probes/pen-sink-probe` PenInjection, NOTES 2026-09-29): tablet proximity (capability mask 0x25C7, pointerType pen/eraser), `leftMouseDown/Dragged/Up` + `tabletPoint` alt tipi, basınç, eğim; hover için `mouseMoved`; sağ/orta düğmeler.
- [ ] **Koordinat dönüşümü tek yerde** (Core, testli): normalize (u16) → sanal ekranın global nokta koordinatları (`CGDisplayBounds`), §1'deki sıkıştırma. Sanal ekran yoksa girdi yok sayılır.
- [ ] Oturum bağlama: `SessionServer` `deliver` → T-022 durum makinesi → injector. `releaseInput` gerçek release-all yapar. Watchdog tick'i oturum kuyruğunda.
- [ ] **Accessibility izni**: yoksa girdi enjekte edilmez, menüde "Erişilebilirlik izni gerekli" + Sistem Ayarları'nı açan menü öğesi; çökme yok. MateBridge.app kendi kimliğiyle izin ister.
- [ ] Çift tıklama için `mouseEventClickState` (§4 POINTER_REL notu) — tek dokunuş/çift dokunuş zamanlamasıyla.
- [ ] Doğrulama aracı: `MateBridgeApp --inject-test` benzeri bir mod, fixture PEN mesaj dizisini (ör. `pen_hover_to_contact`) sanal ekrana enjekte eder; orkestratör Krita'da kontrol eder.
- [ ] `./scripts/check.sh` geçiyor.

## Notlar (T-022 incelemesinden, 2026-09-30)

T-022'nin `InputStateMachine`'ini tüketirken uyulacak sözleşme (PROTOCOL.md §4 ve §7, aynı tarihli netleştirmeler):

- **Oturum başına yeni makine.** Bir oturumun makinesi sonrakine taşınmaz.
- **Tek saat.** `handle(_:now:)` ve `tick(now:)` aynı monoton saatten (`HostClock`) beslenir. Zamanlayıcı `nextDeadline(now:)`'a göre kurulur (mutating; makine `var` olarak tutulur).
- **Tek kuyruk.** Makine kilitsiz bir değer tipidir; mesaj, tick ve release-all yalnızca oturum kuyruğundan çağrılır.
- **`mouseButton` imlecin o anki konumunda uygulanır.** Injector son enjekte ettiği konumu tutar.
- **Kaydırma:** sıfır deltalı `CHANGED` (istemcinin canlılık mesajı) enjekte edilmez. Zorla bitirilen hareket ENDED olarak enjekte edilir ve atalet üretilmez. Release-all, süren ataleti de durdurur (makinede bunun durumu yok; injector'ın işi).
- Kritik: bu kart da Codex `--high` incelemesinden geçer.

## Plan

Hedef: `[InjectAction]` (T-022) -> **`[MacEvent]`** (saf değer tipleri, Core, testli) -> **`MacEventPoster`** (tek küçük dikiş; gerçeği `CGEventPoster`, yalnızca o `CGEvent`'e çevirir ve `.cghidEventTap`'e basar). Basma birim testlerinde yok; tüm dönüşüm ve durum mantığı poster'ın önünde.

**Kısıt ve karar (Open questions'a da yazılacak):** test hedefi yalnızca `MateBridgeCore`'a bağlı ve `Package.swift` kartın `files:` listesinde değil; Core'da yeni dosya olarak yalnızca `Geometry+Display.swift` serbest. Bu yüzden test edilebilir tüm mantık o tek dosyada MARK bölümleri olarak toplanır (ad dar kaldı; bölme/yeniden adlandırma saf taşıma, orkestratör karar verir). Host tarafı (`CGEvent`, izin, sanal ekran bulma, kuyruk/zamanlayıcı) ince bir kabuk olur ve birim testlenemez; Handoff'ta tetikleyici-test eşlemesi ve canlı liste verilir.

**Core (`Geometry+Display.swift`):**
1. `DisplayGeometry` (+`DisplayPoint`): `CGDisplayBounds` origin/boyut + ölçek. Normalize u16 -> global nokta `NormalizedCoord.toPoints` ile (PROTOCOL §1: `[origin, origin+w-1/scale]` sıkıştırma), göreli hareket için aynı sınırlarla `moved`, `center`. Geçersiz (0/NaN) boyut -> `nil`. Testler GEO-*.
2. `MacEvent` sözlüğü: `tabletProximity`, `tabletPoint` (hover/down/drag/up; basınç, eğim, clickState), `mouse` (moved/dragged/down/up, düğme, delta, clickState), `scroll` (piksel deltalı, faz).
3. `ClickCounter`: düğme başına art arda basış sayısı (süre `NSEvent.doubleClickInterval`, mesafe ~5 pt, farklı düğme/uzaklık/zaman -> 1). Kalem basışı her zaman `clickState = 1` (Faz 0 probu; çizim uygulamalarında çift tık istemiyoruz). CLICK-*.
4. `InjectionPlanner`: Mac'in **gölge durumu** (yakınlık aracı, kalem teması, basılı düğmeler + clickState, açık scroll, son imleç konumu, son tablet noktası) ve `plan(actions, environment, now)`. Kural: **açan** eylemler (enter, hover, down, move, button down, scroll began/wheel) yalnızca `canInject && geometry != nil` iken; **kapatan** eylemler (up, leave, button up, scroll end) gölge durumda tutulan şey varsa **her zaman** üretilir (ekran yok/izin yok fark etmez; konum = son bilinen). Gölgede olmayan şeyin drag/up'ı bastırılır (down kapıda düşmüşse). Kapı sonradan açılırsa hover/down için yakınlık kendiliğinden girilir. `mouseButton` son enjekte edilen imleç konumunda uygulanır; sıfır deltalı `scroll(.changed)` enjekte edilmez; kesirli scroll kalanı taşınır; atalet hiç üretilmez (Faz 3), yani `forcedEnd` sonrası atalet yok ve release-all'da durdurulacak atalet de yok. `releaseAll(environment)` gölgede kalan her şeyi bırakır (makineden bağımsız emniyet ağı). Sayaçlar (izin/ekran nedeniyle düşen). PLAN-*.
5. `InputPipeline`: oturum yaşam döngüsü: `sessionStarted` (gölgede artık varsa bırak + **taze** `InputStateMachine`), `handle`/`tick`/`nextDeadline`, `release(cause)` (= `machine.releaseAll` -> planlayıcı + planlayıcı emniyet ağı), `sessionEnded`, `shutdown`. Kapı kapanırsa (ekran gitti / izin gitti) ve gölgede tutulan girdi varsa önce release-all. Makine oturumlar arası taşınmaz. PIPE-* (her §7 tetikleyicisi: `allReleaseCauses` döngüsü, ekran yokken, izin yokken, izin yarıda giderken, takeover sırası) ve rastgele (fuzz) test: rastgele mesaj + rastgele kapı değişimi + rastgele release-all; bağımsız `MacEvent` modeli: çift down yok, up'sız down yok, her release-all sonrası boşta, kapı tamamen açıkken Mac durumu = makine durumu.

**Host (`MateBridgeHost/Input/`):**
- `MacEventPoster` (protokol) + `CGEventPoster`: olay yapımı Faz 0 probundan (`buildProximity`/`buildPoint`): `hidSystemState` kaynağı, proximity `type = .tabletProximity`, yetenek maskesi 0x25C7, `pointerType` pen=1/eraser=3, tablet-point alt tipi, basınç iki alana, eğim, `leftMouseDown/Dragged/Up`, hover için `mouseMoved`. Diğer düğmeler `left/right/otherMouse*`. Scroll `CGEvent(scrollWheelEvent2Source:)` piksel + faz. Atıf: LukeLogix/android-display (Apache-2.0) yaklaşımı, probtan.
- `VirtualDisplayLocator`: sanal ekranı **genel** CG API ile bulur (`CGGetOnlineDisplayList`, vendor 0x4D42 + model 1, `VirtualDisplay.swift`'teki değerler), `CGDisplayBounds` + mod ölçeği -> `DisplayGeometry`; yoksa `nil` (girdi yok sayılır). `VideoPipeline` ekran kimliğini dışarı vermiyor ve dosya listemde değil, bu yüzden bu yol.
- `AccessibilityPermission`: `AXIsProcessTrusted` (kısa TTL önbellek), istem `AXIsProcessTrustedWithOptions(prompt)`; yalnızca uygulama çağırır.
- `InputController`: kendi seri kuyruğu (`SessionServer.queue` private ve dosya listemde değil; oturum kuyruğu `deliver`/`releaseInput`'u zaten eşzamanlı çağırıyor, ben `queue.sync` ile içeri girerek sıra ve geri basınç korunur). Makine + planlayıcı yalnızca bu kuyruktan. Watchdog: `nextDeadline(now:)`'a göre tek atımlık zamanlayıcı, her giriş noktasından sonra yeniden kurulur. 1 sn'lik durum yoklaması: izin/ekran değişimini loglar ve menüye bildirir, kapı kapanınca tutulan girdiyi bırakır. Loglar `component=input`, yalnızca sayaç ve durum değişimi, koordinat yok.
- `InjectTest` (`--inject-test`): fixture PEN dizisini (`--fixture pen_hover_to_contact`) ya da protokol düzeyinde sentetik vuruşu (`--stroke ramp|circle|tilt`) ya da dokunma (`--tap N`) gerçek `InputController` üzerinden, bulunan sanal ekrana enjekte eder; SIGINT/bitişte release-all. Ben ÇALIŞTIRMAM.

**App (`MateBridgeApp/`):** `InjectTestCommand.swift` (üç satırlık kanca), `main.swift`: `InputController` bağlama (`deliver`, `releaseInput`, `sessionStarted/Ended`; `applicationWillTerminate`'te `server.stop()` sonrası `input.shutdown()`), SIGINT/SIGTERM/SIGHUP -> `NSApp.terminate` (kapanış tetikleyicisi), menü: izin yoksa "Erişilebilirlik izni gerekli" + "Sistem Ayarları'nı aç…" öğeleri (durum değişimiyle güncellenir, menü açılırken yoklanır), açılışta izin yoksa bir kez sistem istemi. `StreamCoordinator.swift` değişmez (ekran kimliği yok; bağlama `main.swift`'te yeterli).

**Sıra:** bu plan commit'i -> Core (geometri, MacEvent, ClickCounter, planlayıcı, pipeline) + testleri -> Host kabuğu -> App bağlama -> `check.sh` -> Handoff (kural/tetikleyici -> test tablosu, canlı kontrol listesi).

## Handoff

- **Commit:** kod başı `9f28293` (dal `task/T-023-host-input-injection`, taban `main` 27ac13e; `main` sonradan T-024 ile ilerledi, dala merge/rebase yapılmadı). İlk tur: plan `b618083`, Core + testler `a7279fb`/`09d5232`, Host kabuğu + bağlama `d4621f3`, rötuşlar `e8b2c39`. **İnceleme turu:** `08caff5` kart dosya listesi, `273c5f9` düzeltme 4+5, `a746348` düzeltme 1+2+3, `335e77c` düzeltme 6, `5b7bf4a` düzeltme 7+8, `064289c` `--scroll`/`--wheel` + `input_watchdog` logu + PIPE-26, `9be61b8` başlık yorumu, `55b3b43` düzeltme 9 (yalnızca kod taşıma: parçalar birleştirilince eski dosyayla bayt bayt aynı). **3. tur** (Codex: 3 delik): `9f28293` sıralama + vazgeçmeme + kapanışta boşaltma, testler ve mutasyonlarla. Bunun üstündeki commit yalnızca bu kartı günceller. `./scripts/check.sh`: **ALL OK** (host-mac 286 test / 29 suite; probes, gradle, fixture'lar geçti). Bu ajan hiçbir olay basmadı; uygulamayı/host'u/`--inject-test`'i/`pen-sink-probe`'u çalıştırmadı; TCC'ye dokunmadı.
- **Dokunulan dosyalar:**
  - Core/Input: `Geometry+Display.swift` (artık yalnızca `DisplayGeometry`), yeni `MacEvent.swift`, `ClickCounter.swift`, `InjectionPlanner.swift`, `InputPipeline.swift`, `MacEvent+Closing.swift`, `OwedRelease.swift`, `ReleaseRecord.swift`. `Core/Session/SessionMachine.swift`: yalnızca `ReleaseCause.gateLost`. T-022 dosyalarına dokunulmadı.
  - Host: `Input/{CGEventPoster,VirtualDisplayLocator,AccessibilityPermission,InputController,InjectTest}.swift`; `VirtualDisplay.swift`: yalnızca `vendorID`/`productID` sabitleri.
  - App: `InjectTestCommand.swift`, `main.swift`.
  - Testler: `Tests/MateBridgeCoreTests/Input/{DisplayGeometryTests,InjectionPlannerTests,InputPipelineTests,OwedReleaseTests,SessionInputWiringTests}.swift` ve `InputTestSupport.swift` (`allReleaseCauses`'a `.gateLost`).
  - Bu kart. `StreamCoordinator.swift`, `Package.swift`, PROTOCOL, fixture'lar, `SessionServer.swift` değişmedi.
- **İnceleme turu, düzeltme başına:**
  1. **Başarısız bırakış unutulmaz.** `MacEventPoster.post` artık postalanamayanları döndürür; pen up zengin biçimde kurulamazsa çıplak sol fare up'a düşer (`MacEvent.plainRelease`, MAC-2). `InputController` başarısızları `pipeline.postFailed`'e bildirir; kapatan olaylar (up, leave, scroll end) `OwedRelease`'te (sabit slotlar: pen up, her düğme up, leave, scroll end) bekler ve sonraki `handle`/`tick`/`release`/oturum başında yeniden denenir: ilk 6 deneme >= 250 ms arayla, sonra saniyede bir; **asla vazgeçilmez** (3. tur), yavaş kadansa geçiş slot başına bir kez `input_release cause=owed_slow slowed=N` olarak loglanır (release tetikleyicisi, oturum başı ve kapanış aralığı yok sayar). Testler: OWED-1..10, PIPE-20, 21, 22, PIPE-F3.
  2. **İzin gidince bırakış kaybolmaz.** İzin yokken üretilen kapatan olaylar (ve kontrolcünün son anda yaptığı taze izin denetiminin reddettikleri) `owed`'de tutulur; izin dönünce, oturum başında ve kapanışta, yeni girdiden ÖNCE, güncel ekrana yerleştirilerek yeniden gönderilir (`input_release cause=owed_replay`). İzin beklemek deneme hakkı harcamaz (OWED-6, PIPE-24). Önbellek bayatlığı: kapatan olay içeren her grup için `AXIsProcessTrusted` önbelleksiz denetlenir. Testler: PIPE-5, 6, 23, 24, 26, PIPE-S-1 (izin yok kolu), PIPE-F2/F3. **Dürüst sınır:** izin yokken hiçbir şey bırakılamaz; düğme/kalem basılıyken izin geri alınırsa macOS `up`'ı düşürür, Mac'te düğme izin dönene ya da fiziksel tıklamaya kadar basılı kalabilir. Bu artık "bilinen sınır" değil, geri gelince telafi edilen bir durumdur; kalan tek şey izin yokken beklemektir.
  3. **`ReleaseCause.gateLost`** eklendi (ekran/izin gitti; SessionMachine üretmez). Her release `ReleaseRecord` üretir ve `input_release cause=<ad> events=N pen_up=.. pen_leave=.. buttons=.. scroll=..` olarak loglanır (kapı kaybı `W`, sıfır olaylı tekrarlar `D`); koordinat yok. Testler: PIPE-19, PIPE-2 (13 neden), T-022 testleri de `.gateLost` ile koşar.
  4. **Önbellekteki imleç güncel ekranda geçerli olmalı.** `DisplayGeometry.contains`; geçersiz imleç atılır, merkez kullanılır (düğme basışı, göreli hareket, mutlak hareketin delta'sı, düğme up, kalem up, scroll). Ekran yokken (yalnızca kapatan olaylar) son bilinen konum. Testler: PLAN-40..45; fuzz'da "her konumlu olay o anki ekranın içinde" (PIPE-F2/F3).
  5. **Scroll/tekerlek olayları ekranda konumlanır.** `MacScroll.position` planlayıcıdan (geçerli imleç, yoksa merkez), fabrikada `CGEvent.location` ayarlanır. Testler: PLAN-45. WindowServer'ın konuma göre yönlendirip yönlendirmediği canlı kontrol (adım 6). Ölçüm için `--inject-test`'e `--scroll` (bir kaydırma hareketi) ve `--wheel N` eklendi.
  6. **Vendor/product tek kaynak:** `VirtualDisplay.vendorID/productID`; bulucu onları kullanır. Tanı satırı (`input_displays`, ekran yoksa `input_display_missing`) artık her ekran için `active=`, `mirror=`, `main=` yazar; kapı bunlara bağlı değil.
  7. **Zamanlayıcılar `init`'te** (watchdog + 1 sn yoklama); `deliver` `start()`'tan önce gelse de watchdog var. `start()` yalnızca durum bildirimini bağlar.
  8. **Küçükler:** `--inject-test` bilinmeyen bayrak / artık değer / eksik değerde kullanım mesajı + çıkış kodu 2 (14 argüman durumu scratch'te elle denendi, tool çalıştırılmadan); oturum boyunca `ProcessInfo` etkinliği (`userInitiated` + `latencyCritical`), oturum bitince/kapanışta bırakılır; sıfır deltalı `scroll(.changed)`: PLAN-31 (planlayıcı) ve yeni PIPE-25 (makineden geçerek, 5 keepalive, hiçbir olay yok, hareket açık kalır).
  9. **`Geometry+Display.swift` bölündü** (yalnızca taşıma).
- **3. tur (Codex, owed-release mekanizmasındaki 3 delik):**
  1. **Eski bırakış yeni basışı geçemez.** `owed` boş değilken (ya da bir replay verildi ama henüz onaylanmadıysa: `OwedRelease.isBlocking`) planlayıcının kapısı AÇAN olaylara kapanır, tıpkı izin/ekran yokmuş gibi (`InjectionEnvironment.opensBlocked`; düşenler `droppedOwed` olarak sayılır ve `input_dropped ... owed=N` loglanır). Kapatan olaylar akmaya devam eder ve başarısız olurlarsa owed'e katılır; makine kendi durumunu tutar, yani hâlâ basılı bir parmak sonradan hayalet tıklama olmaz. Her giriş noktası önce replay'i dener (aralığa tabi); kapı, owed boşalıp son replay bir sonraki çağrıda (başarısızlık bildirilmeden) onaylanınca açılır. Tam 0 / 100 / 300 ms dizisi hem düğme hem kalem için testli (PIPE-30, PIPE-31); fuzz'daki atlama kaldırıldı ve iki bağımsız kontrol eklendi: sürücü, Mac'e ulaşmayan kapatan olayları kendi başına tutar ve bir basış (down / enter / scroll began) o slot hâlâ teslim edilmemişken teslim edilirse hata verir (`orderingViolations`), ayrıca Mac modeli hiçbir ihlal görmemeli. Bu yolda bulunan ve düzeltilen dört ek sıralama deliği: (a) poster ilk başarısızlıkta durur, ondan sonraki olaylar (sonraki up/leave/down) postalanmaz ve sırayla başarısız döner; (b) postalanmayan AÇAN olaylar planlayıcı gölge durumundan geri alınır (`InjectionPlanner.notPosted`); aynı başarısız grupta açılışı Mac'e hiç ulaşmamış bırakışlar owed'e girmez, iptal edilir; (c) owed pen up varken üretilen pen leave, owed'e alınır ve up'ın ardından gider (`OwedRelease.replay` leave'i up'sız asla vermez); (d) tekrar deneme zamanlayıcısı owed'in vadesine göre kurulur (izin varken). Testler: PIPE-30..34, 35b, PLAN-50, 51, OWED-10, PIPE-F3/F4.
  2. **Owed asla bırakılmaz.** Altı denemeden sonra silinmez; slot sayısı sabit olduğundan sınırlıdır. Bir kayıt yalnızca postalanınca ya da aynı slot için daha yeni bir kapatan olayla değiştirilince çıkar. İlk 6 replay 250 ms arayla, sonra saniyede bir (`OwedRelease.slowAfterAttempts/slowIntervalUs`); geçiş bir kez loglanır (`owed_slow`, `owed_giveup` yok). Testler: OWED-5 (200 başarısız deneme sonrası hâlâ orada, yaratma düzelince tam bir kez postalanır), OWED-6 (kadans, geçiş slot başına bir kez), OWED-7, OWED-9, PIPE-21 (18 sn hata, sonra kurtarma), PIPE-F3 (poster kapatan olayları 12'ye kadar uzun serilerle kuramıyor, son üçte düzeliyor; sonunda owed boş ve Mac boşta).
  3. **Kapanış boşaltır.** `InputController.shutdown`, son flush'tan sonra `InputPipeline.drainOwed` ile owed'i eşzamanlı yeniden dener: en çok 5 deneme, aralarda 60 ms (toplam ~250 ms), normal aralığı yok sayar; izin yoksa hiç denemez ve dönmez (döngüye girmez), yalnızca loglar: `input_shutdown released=N owed_before_drain=M owed=K permission=P`. Mantık Core'da (posterin ve saatin arkasında) olduğu için sahte posterle testli: PIPE-35 (ilk flush ve ilk deneme başarısız, ikinci başarılı: 1 duraklama), PIPE-36 (izin yok: 0 gönderim, 0 duraklama; izin denemenin ortasında giderse durur), PIPE-37 (hep başarısız: tam 5 deneme, 4 duraklama, hepsi hâlâ owed, sonra bir deneme yine postalar).
- **Mimari (kısa):** `InjectAction` (T-022) -> `InjectionPlanner` -> `MacEvent` -> `MacEventPoster` -> `CGEventPoster` (tek `CGEvent`/`post` yeri). `InputPipeline` = oturumun makinesi (her oturum taze) + Mac'i yansıtan planlayıcı + `OwedRelease`. `InputController` = Host kabuğu: kendi seri kuyruğu, `init`'ten çalışan watchdog + yoklama zamanlayıcıları, izin/ekran örnekleme, gönderme + başarısızlık bildirimi, loglar.
- **Tetikleyici -> yol -> test -> log satırı.** Ortak yol: `SessionMachine` `.releaseInput(_, cause)` -> `handlers.releaseInput` -> `main.swift` `input.releaseInput($0)` -> `InputPipeline.release` -> `machine.releaseAll(cause)` -> planlayıcı -> `CGEventPoster`. Log: `grep 'ev=input_release' ~/Library/Logs/MateBridge/host.log`.

  | Tetikleyici | Neden / log `cause=` | Birim test | Canlı adım |
  |---|---|---|---|
  | `RELEASE_ALL` mesajı | `client_request_N` (arka plan = 1) | PIPE-2, PIPE-3, PIPE-S-1 | 7a |
  | `BYE` gelen / giden | `bye`; giden BYE'lar `releaseInput`'tan SONRA gider | PIPE-2, PIPE-3, PIPE-S-1 | 7b |
  | bağlantı kopması | `disconnected` | PIPE-2, PIPE-S-1, PIPE-S-3 | 7c |
  | protokol hatası | `protocol_error` | PIPE-2, PIPE-S-1 | (tetiklemek zor; yalnız birim) |
  | 1,5 sn sessizlik / 5 sn kapanış | `silence` / `timeout` | PIPE-2, PIPE-S-1 | 7d |
  | oturum devralma | `superseded`, sonra yeni oturum | PIPE-9, PIPE-S-1, PIPE-S-2 | 7e |
  | uygulama kapanışı | `shutdown` (+ `input_shutdown released=N owed_before_drain=M owed=K permission=P`); SIGINT/SIGTERM/SIGHUP -> `terminate` | PIPE-2, PIPE-11, PIPE-35..37, PIPE-S-1 | 2 |
  | oturum bitti ama release gelmediyse | `sessionEnded` yedeği | PIPE-10 | - |
  | ekran / izin gitti (bir şey basılıyken) | `gate_lost` | PIPE-4, 6, 7, 16, PIPE-F2/F3 | 8, 9 |
  | reddedilen / başarısız bırakış | `owed_replay`, `owed_slow`, `input_post_failed`, `input_dropped ... owed=` | PIPE-5, 6, 20..24, 26, 30..37, OWED-*, PIPE-F3/F4 | 8 |
  | kalem/scroll watchdog (500 ms) | `input_watchdog events=N` (release değil) | PIPE-8 (Core); zamanlayıcı kabuğu birim testsiz | 10 |

  `PIPE-S-1` gerçek `SessionMachine`'i sürer (8 tetikleyici x 3 kapı durumu = 24 durum); izin yok kolunda bırakışın `owed`'e girdiğini ve izin dönünce Mac'in boşaldığını doğrular.
- **Kural -> test eşlemesi (öteki):**

  | Kural | Testler |
  |---|---|
  | §1 dönüşüm, origin (negatif dahil), `1/scale` sınırı, geçersiz ekran, `contains` | GEO-1..8 |
  | Ekran/izin yoksa açan eylemler düşer; kapatanlar hep üretilir; gölgede olmayanın up'ı bastırılır | PLAN-9, 20..24, 27 |
  | Önbellek konumları güncel ekrana göre (imleç, kalem, scroll) | PLAN-40..45, MAC-3, OWED-3, PIPE-F2/F3 |
  | Kalem olayları, eraser, birimler, otomatik yakınlık, çift tıklama, scroll | PLAN-1..8, 10..18, 30..37, CLICK-1..6, PIPE-15, 17 |
  | Kapatan olay sözlüğü ve düşük biçim | MAC-1, MAC-2 |
  | Owed: slotlar, sıra, aralık, yavaş kadans, asla vazgeçmeme, izin beklemek bedava, onay, leave up'ı geçmez | OWED-1..10 |
  | Eski bırakış yeni basışı geçemez (düğme, kalem, pen priority; kapı kapanır, kapatanlar akar) | PIPE-30, 31, 32, 35b, PIPE-F3/F4 (sürücünün bağımsız `orderingViolations` kontrolü + Mac modelinde ihlal yok) |
  | Poster ilk başarısızlıkta durur; postalanmayan açanlar gölge durumdan geri alınır; açılışı ulaşmamış bırakış iptal | PLAN-50, 51, PIPE-34, 35b, PIPE-F3 |
  | Pen leave owed pen up'ı geçmez | PIPE-33, OWED-10 |
  | Kapanışta owed boşaltma (sınırlı, izinsizken dönmeden) | PIPE-35, 36, 37 |
  | Planlayıcı emniyet ağı | PIPE-18, PIPE-F1/F2/F3 (`reconciliations == 0`) |
  | Rastgele | PIPE-F1 (400 tohum: Mac = makine), PIPE-F2 (600: izin/ekran gelip gidiyor, Mac yalnızca teslim edilenleri görür, konumlar ekranın içinde), PIPE-F3 (600: ek olarak poster kapatan olayı kuramıyor, önbellek bayat; sonunda owed boş ve Mac boşta) |

  Testlerin hata yakaladığı **55 mutasyonla** elle doğrulandı (ilk tur 21, inceleme turu 19, 3. tur 15: kapı hiç kapanmıyor, onaylanmamış replay bloklamıyor, altı denemede vazgeçme, yavaş kadans yok, geçiş sayılmıyor, boşaltma son denemeden sonra da duraklıyor / aralığa uyuyor (drain'in kendi izin koruması eşdeğer mutant çıktı: `replayOwed` aynı korumayı taşıyor, döngüye girme yine yok), leave up'ı geçiyor, replay bağımlılığı yok, açılışı ulaşmamış bırakış owed'e giriyor, gölge geri alınmıyor, replay hiç onaylanmıyor, planlayıcı bloğu yok sayıyor, geri çekilme yanlış deneme sayısı; ilk iki tur: konum geçerliliği, scroll konumu, izin yokken owed, izin yokken replay, `handle`/oturum başı/release'te replay, kapı kaybı nedeni, başarısız postu unutmak, sınırsız deneme, aralıksız deneme, sıra, iade, `isClosing`, `placed`, düşük biçim...). Sağ çıkanlar (PLAN-9, PLAN-34b, N4) için test eklendi (PLAN-9, 34b, PIPE-26) ve üçü de kırmızı verdi.
- **Yan doğrulama (basmadan, scratchpad'de, commit'lenmemiş):** (a) `CGEventFactory` ile her `MacEvent` türünden `CGEvent` kurup alanları geri okudum: proximity (`pointerType` 1/3, maske 0x25C7), tablet nokta, fare (düğme 0..4, clickState, delta), **scroll (faz 1/2/4/8, momentum 0, delta, `location` = verilen konum)**; hepsi beklenen değer. `CGEvent.post` çağrısı yok. (b) `InjectTest.parse`: 14 argüman durumu (yazım hatası, bilinmeyen bayrak, artık değer, eksik değer, başka aracın bayrağı, aralık dışı sayılar reddedildi; geçerli olanlar kabul). (c) Bulucunun olumsuz yolu: bu Mac'te tek ekran (1920x1080, ölçek 1, vendor `0x756e6b6e`/model `0x76697274`, active=1 mirror=0 main=1), MateBridge ekranı yok.
- **Varsayımlar / bilinçli seçimler:**
  1. Kabul edilenler (orkestratör): kontrolcünün kendi seri kuyruğu + `queue.sync`; vendor/product ile ekran bulma; parmak çift tıklama mesafesi 12 pt (cihazda ayarlanacak).
  2. `now`, kuyrukta işlenme anında alınır (tüm giriş noktalarında monoton); soketten alınma anına en fazla kuyruk bekleme süresi kadar geç.
  3. Kalem clickState her zaman 1; dokunma/fare sayılır (süre `NSEvent.doubleClickInterval`, `InputController` oluşurken okunur). Scroll: piksel birimli, faz `CGScrollPhase`, momentum yok; yön/ölçek/his doğrulanmadı (Faz 3). Silgi: yalnızca `pointerType` 3, `pointerID` kalemle aynı.
  4. Otomatik yakınlık girişi Mac tarafı bir karar (kapı kapalıyken düşen `enter`'ın ardından ilk hover/down önce `enter` basar). Bayat izin önbelleğinde macOS'un sessizce düşürdüğü AÇAN olaylar (down gibi) bildirilmez: zararsızdır, `up`'ı sonradan gelir.
  5. İzin istemi açılışta bir kez; Terminal'den başlatılırsa `AXIsProcessTrusted` Terminal'in iznini yansıtabilir. SIGINT/SIGTERM/SIGHUP -> `NSApp.terminate`.
  6. `CGEvent` hiç kurulamazsa (pratikte olmaz) kapatan olay `owed`'e girer ve asla vazgeçilmez: ilk 6 deneme 250 ms arayla, sonra saniyede bir (`event_create_failed`, `input_post_failed`, `owed_slow`); owed doluyken açan girdi bloklu kalır.
- **Test edilmeyenler / cihazda doğrulanacaklar:** Birim testler Core'u kapsar (dönüşüm, planlayıcı, pipeline, owed, gerçek `SessionMachine`'li tetikleyici testleri, rastgele testler). Host kabuğu birim testsiz: `CGEventPoster` (gerçek Krita'da olay alanları, düşük biçim), `VirtualDisplayLocator`, `AccessibilityPermission`, `InputController` kuyruğu/zamanlayıcıları/etkinliği/taze izin denetimi, owed vadesine göre uyanma, shutdown boşaltmasının bağlanışı (mantığı Core'da testli), `main.swift` bağlama satırları, sinyaller, menü, `--inject-test`. **Canlı kontrol listesi, bu sırayla** (bir seferde tek adım; hazırlık: `./scripts/bundle-host.sh`; başka MateBridge / `--dump-video` çalışmasın: sabit seri numaralı tek sanal ekran; Krita kurulu; ayrı terminalde `tail -f ~/Library/Logs/MateBridge/host.log | grep 'ev=input'`):
  1. **Bulucu eşleşmesi ve izin kimliği.**
     a. `open build/MateBridge.app` (Terminal'den DEĞİL, kendi kimliğiyle). Beklenen: sistem Erişilebilirlik istemi bir kez; menüde "Erişilebilirlik izni gerekli" + "Sistem Ayarları'nı aç…"; log `input_gate accessibility=0`. "Sistem Ayarları'nı aç…" Gizlilik > Erişilebilirlik'i açar. İzni ver: <= 1 sn içinde iki menü satırı kaybolur, log `accessibility=1` (olmazsa uygulamayı yeniden başlat ve not et).
     b. Tableti bağla: `input_session_start`, `input_gate accessibility=1 display=1`, ardından `input_displays count=.. displays=v0x4d42/m0x1/2800x1840/active=?/mirror=?/main=?`. **`display=1` gelmezse** `input_display_missing displays=...` satırını bana ilet (bulucu eşleşmiyor demektir). `display=1` ise `active`, `mirror`, `main` değerlerini bana yaz (yeni tanı alanları; kapı bunlara bağlı değil).
     c. Uygulamadan çık. `build/MateBridge.app/Contents/MacOS/MateBridgeApp --inject-test --create-display --countdown 3 --tap 1` (uygulama kapalı, tablet yok): `virtual display: 1400x920 pt, scale 2.0, ...` yazmalı; "created but not found by vendor/product" derse dur.
  2. **Çık-sonra-bırak (vuruş ortasında).** Krita'da tuval açık, pencere sanal ekranda:
     a. `--inject-test --create-display --stroke ramp --repeat 20 --countdown 5` çalışırken Ctrl-C: `interrupted: input released`, tuvalde takılı çizgi yok, fareyle normal tıklanır.
     b. Aynısı, başka terminalden `kill -TERM $(pgrep -f 'inject-test')`.
     c. Uygulama + tablet: tablette çizerken menüden **Quit**: çizim durur, `input_shutdown released=N owed_before_drain=0 owed=0 permission=1`, fare normal.
     d. Uygulamayı Terminal'den çalıştırıp çizerken **Ctrl-C**; ve `kill -TERM <pid>`: aynı sonuç (`terminate` yolu).
  3. **Krita basınç, eğim, silgi** (`--inject-test --create-display --countdown 8`): `--stroke ramp` (ince -> kalın -> ince, kalınlık/opaklık), `--stroke circle` (yuvarlak daire, elips değil), `--stroke tilt` (eğime duyarlı fırça; eğim işareti geçici, ters ise yönü not et), `--fixture pen_hover_to_contact` (ekranın ~%34/%19 noktasında küçük iz), `--fixture pen_eraser` (Krita silgi olarak algılar). Sonra tabletle: hafif/sert basınç, eğim, hover çerçevesi, M-Pencil çift dokunma -> silgi, tekrar -> kalem.
  4. **Koordinatlar: sıfır, sıfır olmayan ve negatif origin; yeniden düzenleme.** Kalemle tablette dört köşeye ve ortaya yaklaş; imleç/Krita çerçevesi tam aynı noktaya gider, köşede ekranın köşesine oturur, dışına taşmaz. Bunu üç düzende tekrarla (Sistem Ayarları > Ekranlar > Düzenle): (a) sanal ekran ana ekran (origin 0,0), (b) sağda (origin x > 0), (c) solda/üstte (negatif origin). (d) **Kalem tablette hover ederken** düzeni sürükleyerek değiştir: kalem yeni yerde sanal ekranı izlemeye devam eder, fiziksel monitöre sıçramaz; ardından tek dokunuş tıklaması (düğme-only) tablet ekranında olur, eski noktada değil.
  5. **Dokunma ve çift dokunma.** Parmakla dokunma o noktaya tıklar; hızlı iki dokunma çift tıklamadır (Finder'da açar / TextEdit'te kelime seçer; olmazsa 12 pt mesafeyi not et); sürükleme sürükler; kalem menzildeyken avuç dokunuşu yok sayılır (1 sn kapı). `--inject-test ... --tap 2` ile de bak.
  6. **Kaydırma, fiziksel fare başka ekranda.** Sanal ekranın ortasına uzun bir sayfa (Safari) koy; fiziksel farenin imlecini fiziksel monitördeki kaydırılabilir başka bir pencerenin üstüne park et ve elleme. `--inject-test --create-display --scroll` (sonra `--wheel 5`): **sanal ekrandaki sayfa** kaymalı, fiziksel monitördeki pencere kaymamalı (WindowServer konuma göre yönlendiriyor mu, asıl soru bu). Yön: parmak aşağı (dy > 0) sayfayı aşağı taşımalı (doğal); ters ise not et (Faz 3'te düzeltilir).
  7. **Her tetikleyici gerçek ağda** (tablet + uygulama; her birinde çizim sırasında tetikle; sonuç: çizim durur, Mac'te düğme basılı kalmaz, log `ev=input_release cause=... events=N pen_up=1 pen_leave=1`):
     a. tablette uygulamayı arka plana at -> `client_request_1`;
     b. tablette çıkış/BYE varsa -> `bye`;
     c. tablette uygulamayı zorla durdur -> `disconnected`;
     d. tablette Wi-Fi'ı kapat / USB'yi çek -> ~1,5 sn sonra `silence` (5 sn'de `timeout` olaysız);
     e. çizerken tablette uygulamayı yeniden başlat (aynı cihaz devralma) -> `superseded`, `input_session_start`; yeni oturumda yarım kalmış eski vuruş çizim başlatmaz.
  8. **Erişilebilirlik iptal / yeniden ver.**
     a. Kalem **hover** ederken Sistem Ayarları'ndan MateBridge iznini kapat: <= 1 sn içinde menüde uyarı, `input_gate accessibility=0`, `input_release cause=gate_lost events=1 pen_leave=1`, imleç kalemi izlemez, çökme yok. İzni aç: `input_gate accessibility=1`, `input_release cause=owed_replay events=1 pen_leave=1` (uyarı seviyesi), kalem sonraki hareketle yeniden görünür.
     b. Krita'da **çizim sırasında** (kalem aşağıda) izni kapat: `cause=gate_lost pen_up=1 pen_leave=1`. Krita'daki vuruşun bitip bitmediğine bak (macOS `up`'ı düşürür: beklenen sınır, vuruş takılı kalabilir ve fiziksel tıklama bırakır). İzni geri aç: `cause=owed_replay pen_up=1 pen_leave=1` ve Krita vuruşu biter. Sonucu yaz.
     c. İzin kapalıyken uygulamadan çık: `input_shutdown released=N owed_before_drain=M owed=M permission=0` (boşaltma izin yokken denemez, döngüye girmez). M > 0 dürüst sınırdır: `owed` bellekte tutulur, süreç bitince kaybolur (Faz 4).
     d. Not: izin dönünce owed replay'i bir çağrıda gider ve girdi bir sonraki mesajla açılır (aynı çağrıdaki basış bilerek düşer); ilk hareketten hemen sonra kalemin görünmesi normaldir.
  9. **Sanal ekran vuruş ortasında düşerse.** Tablette çizerken Sistem Ayarları > Ekran ve Sistem Ses Kaydı'ndan MateBridge iznini kaldır (video hattı düşer, sanal ekran kalkar; `pipeline_failed`/`display_teardown`): <= 1 sn içinde `input_gate ... display=0` ve `input_release cause=gate_lost pen_up=1 pen_leave=1`; fiziksel monitörde imleç hiç oynamamalı ve hiçbir şey tıklanmamalı. Ekran 1 sn sonra yeniden kurulursa `display=1` ve kalem çalışır. (Bu adım izin değiştirir; tetikleme yolu bulunamazsa atla ve yalnız 4d + 8a'yı say.)
  10. **Watchdog zamanlaması, host arka planda uzun süre boştayken.** Uygulama başka uygulamaların arkasında >= 10 dk boşta kalsın (App Nap adayı), sonra tableti bağla, kalemle hover et ve tablette Wi-Fi'ı kapat: Krita çerçevesi son hover'dan ~0,5 sn sonra kaybolmalı (1 sn'yi geçmemeli); log `input_watchdog events=1` (ardından ~1,5 sn'de `silence` olaysız). Taze başlatılmış uygulamayla aynı süreyi karşılaştır.
  11. **Menü:** Sistem Ayarları'ndan izni kapatıp aç, menünün <= 1 sn içinde güncellendiğine bak.
  Sonuçlar `docs/NOTES.md`'ye (orkestratör): Krita'da basınç/eğim/silgi, clickState, eğim yönü, scroll yönü/yönlendirme, `display=1` eşleşmesi ve `active/mirror/main`, izin iptalinde vuruşun davranışı.
- **Açık sorular / bilinen sınırlar:**
  - **SIGKILL veya çökme** sırasında Mac'in girdi durumu (basılı düğme, kalem yakınlığı) olduğu gibi kalır; kurtarma mekanizması kurulmadı (orkestratör: Faz 4 için bilinen sınır). Aynı sınır: `owed` bellekte tutulur, süreç ölürse kaybolur.
  - İzin yokken hiçbir şey bırakılamaz (macOS olayları düşürür); telafi izin dönünce yapılır (kayıt asla silinmez).
  - **Kalıcı gönderim hatası:** `owed` boşalana kadar açan girdi (kalem, dokunma, fare, scroll başlangıcı) bloklu kalır; Mac'te bir düğme basılıyken girdinin ölü olması bilinçli seçimdir (kaydırma/sürükleme devam eder, bırakış saniyede bir denenir).
  - Bayat izin önbelleğinde macOS'un sessizce düşürdüğü AÇAN olaylar (kapatan olay içermeyen gruplarda) bildirilmez: planlayıcı Mac'in bir adım önünde kalabilir, zararsızdır (fazladan bir up).
  - Kapanış boşaltması sınırlıdır (5 deneme, ~250 ms): o sürede hâlâ postalanamazsa süreç çıkarken `owed` kaybolur (`input_shutdown ... owed=K` ile görünür).
  - `Package.swift`'e bir `MateBridgeHostTests` hedefi (ya da kabuk mantığının Core'a taşınması) gerekir mi? Host kabuğu birim testsiz.
  - `VideoPipeline` ekran kimliğini `public var displayID` yaparsa (dosyam dışında) bulucunun vendor/model araması kalkar.
  - Scroll yönü/ölçeği/atalet ve klavye Faz 3'te; `KEY` hâlâ makinede yok.
  - İşaretçi düğmeleri için watchdog yok (T-022'den devir): takılan ama kalp atışı süren bir istemci bir düğmeyi basılı tutabilir. Faz 3.
