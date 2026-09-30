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

- **Commit:** kod başı `e8b2c39` (dal `task/T-023-host-input-injection`, taban `main` 27ac13e; plan `b618083`, Core + testler `a7279fb`/`09d5232`, Host kabuğu + uygulama bağlama + oturum-bağlama testleri `d4621f3`, son rötuşlar `e8b2c39`). Bunun üstündeki commit yalnızca bu kartı günceller. `./scripts/check.sh`: **ALL OK** (host-mac 246 test / 25 suite; probes ve gradle geçti). Bu ajan hiçbir olay basmadı, uygulamayı/host'u/`--inject-test`'i/`pen-sink-probe`'u çalıştırmadı, TCC'ye dokunmadı (aşağıdaki "Yan doğrulama" hariç, o da basmaz).
- **Dokunulan dosyalar:**
  - Core: `MateBridgeCore/Input/Geometry+Display.swift` (yeni; T-022 dosyalarına dokunulmadı).
  - Host: `MateBridgeHost/Input/{CGEventPoster,VirtualDisplayLocator,AccessibilityPermission,InputController,InjectTest}.swift` (yeni).
  - App: `MateBridgeApp/InjectTestCommand.swift` (yeni), `MateBridgeApp/main.swift` (bağlama, menü, sinyaller).
  - Testler: `Tests/MateBridgeCoreTests/Input/{DisplayGeometryTests,InjectionPlannerTests,InputPipelineTests,SessionInputWiringTests}.swift` (yeni).
  - Bu kart. `StreamCoordinator.swift`, `Package.swift`, PROTOCOL, fixture'lar, `VirtualDisplay.swift`, `SessionServer.swift` değişmedi.
- **Mimari (kısa):** `InjectAction` (T-022) -> `InjectionPlanner` -> `MacEvent` (saf değerler) -> `MacEventPoster` (dikiş) -> `CGEventPoster` (tek `CGEvent`/`post` yeri). `InputPipeline` = oturumun makinesi (her oturum taze, kilitli) + Mac'i yansıtan planlayıcı (oturumlar arası kalır) + release-all. `InputController` = Host kabuğu: kendi seri kuyruğu, watchdog zamanlayıcısı (`nextDeadline`), 1 sn kapı yoklaması, izin/ekran örnekleme, loglar.
- **Kart notlarının ("T-022 incelemesinden") karşılığı:** (1) oturum başına yeni makine: `InputPipeline.sessionStarted` (PIPE-9, PIPE-S-2); (2) tek saat: `HostClock.nowUs()` ile `handle`/`tick`/`nextDeadline`; (3) tek kuyruk: `InputController.queue`, makine `var`; (4) `mouseButton` son enjekte edilen imleç konumunda: `InjectionPlanner.cursor` (PLAN-10/11); (5) sıfır deltalı `scroll(.changed)` enjekte edilmez (PLAN-31), `forcedEnd` -> Mac'e ENDED, atalet üretilmez (PLAN-32), release-all açık scroll'u bitirir (PLAN-25, PIPE-2). Atalet hiç üretilmediği için "süren ataleti durdur" bu kartta boştur; Faz 3 atalet eklerken planlayıcının `releaseAll`/`forcedEnd` yollarına bağlanacak.
- **Tetikleyici -> yol -> test** (PROTOCOL §7). Ortak yol: `SessionMachine` `.releaseInput(_, cause)` -> `SessionServer` `handlers.releaseInput` -> `main.swift` `input.releaseInput($0)` -> `InputPipeline.release` -> `machine.releaseAll(cause)` -> planlayıcı -> `CGEventPoster`.

  | Tetikleyici | Neden | Birim test (Core) | Canlı (Host kabuğu) |
  |---|---|---|---|
  | `RELEASE_ALL` mesajı | `.clientRequest(r)` | PIPE-2 (5 neden), PIPE-3, PIPE-S-1 | 11a |
  | `BYE` gelen / giden | `.bye`; giden BYE'lar (`superseded`, `timeout`, `protocolError`, `shutdown`) `releaseInput`'tan SONRA gider | PIPE-2, PIPE-3, PIPE-S-1 | 11e |
  | bağlantı kopması | `.disconnected` | PIPE-2, PIPE-S-1, PIPE-S-3 | 11c |
  | protokol hatası | `.protocolError` | PIPE-2, PIPE-S-1 | (tetiklemek zor; yalnız birim) |
  | 1,5 sn sessizlik / 5 sn kapanış | `.silence` / `.timeout` | PIPE-2, PIPE-S-1 | 11b |
  | oturum devralma | `.superseded`, sonra `sessionEnded`, sonra yeni `sessionStarted` | PIPE-9, PIPE-S-1, PIPE-S-2 | 11d |
  | uygulama kapanışı | `.shutdown` (`server.stop()`), sonra `input.shutdown()`; SIGINT/SIGTERM/SIGHUP -> `terminate` | PIPE-2, PIPE-11, PIPE-S-1 | 11e (menüden Quit ve Ctrl-C) |
  | oturum bitti ama release gelmediyse | `sessionEnded` yedeği | PIPE-10 | - |
  | sanal ekran kayboldu | kapı kapanır -> ilk mesaj/tick/yoklamada release | PIPE-4, PIPE-7, PIPE-16, PIPE-F2 | 13 |
  | Erişilebilirlik izni gitti / yok | aynı | PIPE-5, PIPE-6, PIPE-F2, PIPE-S-1 (izin yok kolu) | 12 |
  | kalem/scroll watchdog | `nextDeadline`'da `tick` | PIPE-8 (Core); zamanlayıcı kabuğu birim testsiz | 11f |

  `PIPE-S-1` gerçek `SessionMachine`'i sürer (8 tetikleyici x 3 kapı durumu: açık / sanal ekran yok / izin yok = 24 durum): elde kalem teması + sağ düğme + açık scroll varken tetikleyici, sonunda bağımsız `MacEvent` modeli boşta. Tetikleyicinin Host'taki bağlanışı `main.swift`'te handler başına bir kapatma (`releaseInput`, `sessionStarted/Ended`, `deliver`); onu birim test görmez, yukarıdaki "Canlı" sütunu görür.
- **Kural -> test eşlemesi (öteki):**

  | Kural | Testler |
  |---|---|
  | §1 dönüşüm: origin eklenir (negatif dahil), `[origin, origin+w-1/scale]`, geçersiz ekran, göreli hareket sıkıştırma | GEO-1..8 |
  | Ekran/izin yoksa açan eylemler düşer ve sayılır; kapatanlar hep basılır; gölgede olmayanın drag/up'ı bastırılır | PLAN-9, 20..24, 27 |
  | Kapı sonradan açılırsa hover/down için yakınlık kendiliğinden girilir | PLAN-8, PIPE-6, PIPE-14, PIPE-16 |
  | Kalem: enter/hover/down/drag/up/leave, eraser, birimler (nokta, 0..1 basınç, -1..1 eğim), araç değişimi, çift enter/down | PLAN-1..8, PIPE-17 (fixture `pen_hover_to_contact`) |
  | Çift tıklama (süre, mesafe, düğme, saat geri, release-all sıfırlar); up, down'ın sayısını tekrarlar; kalem hep 1 | CLICK-1..6, PLAN-4, 15, 16, PIPE-15 |
  | Fare/dokunma: taşı, `dragging` yalnız basılı düğme için, göreli hareket merkezden başlar | PLAN-10..14, 17, 18 |
  | Scroll: faz, kesir taşıma (x ve y), keepalive, zorla bitiş, iptal, tekerlek, izinsiz bitiş | PLAN-30..37 |
  | Planlayıcı emniyet ağı (planlayıcı ⊆ makine), sayaç `reconciliations` | PIPE-18 (hata enjeksiyonu), PIPE-F1/F2 (sayaç 0) |
  | Rastgele: kapı hep açık -> Mac durumu = makine durumu, hiçbir şey takılı kalmaz (400 tohum x 250 adım); kapı gelip gidiyor -> ihlal yok, kapı kapalıyken Mac'te basılı şey yok, her release sonrası boşta ve ikincisi olaysız (600 tohum) | PIPE-F1, PIPE-F2 |

  Testlerin hata yakaladığı 21 mutasyonla elle doğrulandı (ör. kapatan eylemi kapıya bağlamak, kapı kaybında release'i atlamak, otomatik enter'ı kaldırmak, keepalive'ı enjekte etmek, kalem clickState'i, release'te planlayıcı emniyet ağını / `reconcile`'ı / oturum sonu release'ini / kapanış release'ini kaldırmak, oturumda eski makineyi tutmak, origin'i yok saymak, `1/scale` sınırını atmak, süre sınırını dışlayıcı yapmak). İlk turda ikisi sağ çıktı (kalem up'ı kapıya bağlı: leave onu kurtarıyordu -> PLAN-9; yatay scroll kalanı -> PLAN-34b); testler eklendi, ikisi de kırmızı verdi. Hepsi geri alındı.
- **Yan doğrulama (basmadan):** `CGEventFactory`'yi scratchpad'de (commit'lenmemiş, `CGEvent.post` çağrısı yok) derleyip her `MacEvent` türü için oluşan `CGEvent`'i alan alan geri okudum: proximity (`pointerType` pen=1 / eraser=3, yetenek maskesi 0x25C7, enter bayrağı), tablet nokta (tip, `tabletPoint` alt tipi, konum, basınç iki alanda, eğim, clickState down/up=1, düğme 0), fare (tip, düğme numarası 0..4, clickState, delta), scroll (faz 1/2/4/8, momentum 0, delta). Hepsi beklenen değeri okudu (basınç/eğim 16-bit saklanıyor, 0.005 toleransla; probun testiyle aynı). Aynı araç, bu Mac'te tek ekran gördü (1920x1080, ölçek 1, vendor `0x756e6b6e` / model `0x76697274`), MateBridge sanal ekranı yok -> bulucunun olumsuz yolu çalıştı.
- **Varsayımlar / bilinçli seçimler:**
  1. **Dosya yeri.** Test hedefi yalnızca `MateBridgeCore`'a bağlı ve `Package.swift` kartın listesinde yok; Core'da yeni dosya olarak yalnızca `Geometry+Display.swift` serbest. Test edilebilir tüm mantık (geometri, olay sözlüğü, tıklama sayacı, planlayıcı, pipeline) o tek dosyada MARK bölümleri olarak durur. Ad dar kaldı; bölmek/yeniden adlandırmak saf taşımadır (orkestratör kararı).
  2. **Ayrı girdi kuyruğu.** `SessionServer.queue` private ve dosya listemde değil; `InputController` kendi seri kuyruğunu kullanır ve oturum kuyruğundan gelen `deliver`/`releaseInput`/`sessionStarted/Ended` çağrılarına `queue.sync` ile girer. Sıra ve geri basınç korunur (yavaş poster TCP okumayı yavaşlatır, bellek büyümez); oturum kuyruğuna geri çağrı olmadığından kilitlenme yok. Watchdog ve 1 sn yoklama aynı kuyrukta. `now` kuyrukta işlenme anında alınır (tüm giriş noktalarında monoton); soketten alınma anına en fazla kuyruk bekleme süresi kadar geç.
  3. **Sanal ekranı bulma.** `VideoPipeline` ekran kimliğini dışarı vermiyor (dosya listemde yok). `VirtualDisplayLocator` genel CG çağrılarıyla vendor `0x4D42` + model `1` (VirtualDisplay.swift'teki değerler) eşleşen çevrimiçi ekranı bulur; bulamazsa `nil` = girdi yok sayılır (başka ekrana asla gitmez). Sabitler iki yerde durur (kopya, yorumla işaretli). Bulunamazsa log `input_display_missing displays=...` çevrimiçi ekranların vendor/model/boyutunu yazar.
  4. **`ReleaseCause`'ta "ekran/izin gitti" yok** (dosya kapsamım dışı): kapı kaybı release'i `.disconnected` nedeniyle yapılır (yalnızca tanı alanı).
  5. **Kalem clickState her zaman 1** (Faz 0 probu; çizimde çift tık istemiyoruz). Dokunma/fare tıklamaları sayılır: süre `NSEvent.doubleClickInterval` (`InputController` oluşurken okunur), mesafe **12 pt** (~2 mm; 1 pt ≈ 0,19 mm; parmak dokunuşlarının sapması için; ilk planda 5 pt'ydi, cihazda ayarlanacak). Farklı düğme, uzak, geç, saat geri veya release-all: 1.
  6. **Scroll bu kartta temel düzeyde:** piksel birimli, faz alanı `CGScrollPhase` (began 1 / changed 2 / ended 4 / cancelled 8), momentum yok. Yön, ölçek ve his doğrulanmadı (Faz 3).
  7. **Silgi:** yalnızca `pointerType` 3; `pointerID` kalemle aynı (1) tutuldu (probun doğruladığı yapılandırmadan tek fark). Krita'da doğrulanacak.
  8. **Otomatik yakınlık girişi** yalnızca Mac tarafı bir karar: kapı kapalıyken düşen `enter`'ın ardından kapı açılırsa ilk hover/down önce `enter` basar (yoksa kalem kaldırılıp yaklaştırılana kadar görünmezdi). PROTOCOL'ü etkilemez.
  9. **Açılışta bir kez** `AXIsProcessTrustedWithOptions(prompt)` (izin yoksa sistem istemi); menü öğeleri izin gelene kadar görünür. Terminal'den başlatılırsa `AXIsProcessTrusted` Terminal'in iznini yansıtabilir.
  10. **Sinyaller:** SIGINT/SIGTERM/SIGHUP artık `NSApp.terminate` yapar (kapanış tetikleyicisi olsun diye). SIGKILL/çökmede hiçbir şey yapılamaz.
  11. **Bilinen sınırlar:** (a) düğme/kalem basılıyken Erişilebilirlik izni geri alınırsa `up` olayı macOS'ta düşer, Mac'te düğme basılı kalabilir (fiziksel fare tıklaması bırakır); durum bizde sıfırlanır. (b) `CGEvent` oluşturulamazsa (pratikte olmaz) o olay atlanır ve `event_create_failed` sayaçlı loglanır; gölge durum yine de sıfırlanır.
- **Test edilmeyenler / cihazda doğrulanacaklar:** Birim testler Core'u kapsar (dönüşüm, planlayıcı, pipeline, gerçek `SessionMachine`'li tetikleyici testleri). Host kabuğu birim testsiz: `CGEventPoster` (gerçek Krita'da olay alanları), `VirtualDisplayLocator`, `AccessibilityPermission`, `InputController` kuyruğu + zamanlayıcıları, `main.swift` bağlama satırları, sinyaller, menü, `--inject-test` (Host'u test eden hedef yok; `Package.swift` listemde değil, Açık sorular). **Canlı kontrol listesi, sırayla** (bir seferde tek adım; hazırlık: `./scripts/bundle-host.sh`; başka MateBridge / `--dump-video` çalışmasın: sabit seri numaralı tek sanal ekran; Krita kurulu; loglar: `grep 'ev=input' ~/Library/Logs/MateBridge/host.log`):
  1. **İzin (kendi kimliğiyle).** `open build/MateBridge.app` (Terminal'den DEĞİL). Beklenen: sistem Erişilebilirlik istemi bir kez; menüde "Erişilebilirlik izni gerekli" + "Sistem Ayarları'nı aç…"; log `ev=input_gate accessibility=0`. "Sistem Ayarları'nı aç…" Gizlilik ve Güvenlik > Erişilebilirlik'i açar. İzni ver: <= 1 sn içinde iki menü satırı kaybolur, log `accessibility=1` (olmazsa uygulamayı yeniden başlat ve not et). Sonra uygulamadan çık (Quit).
  2. **Mac yarısı, ağsız: `--inject-test`** (uygulama kapalı; araç `--create-display` ile kendi sanal ekranını yapar; Krita'da yeni tuval açık; bu süreç Erişilebilirlik iznine sahip olmalı, en kolayı paket içindeki ikili): `build/MateBridge.app/Contents/MacOS/MateBridgeApp --inject-test --create-display --countdown 8 --stroke ramp`. Geri sayımda Krita penceresini yeni (sanal) ekrana taşı. Beklenen: `virtual display: 1400x920 pt, scale 2.0, ...` satırı (bulucunun vendor/model varsayımını doğrular; "created but not found by vendor/product" derse dur ve bana bildir), tuvalde ekranın %25-%75'i arasında ortada yatay çizgi, kalınlık/opaklık ince -> kalın -> ince (Basic-5 Size Opacity), son satır `done: N messages injected, input released`, kalem menzilden çıkar.
  3. Aynı komutla `--stroke circle` (yuvarlak daire, elips değil; basınç halka boyunca değişir) ve `--stroke tilt` (eğime duyarlı fırça, ör. Sketch/kurşun kalem; eğim işareti geçicidir, ters ise yönü not et, kalibrasyon T-025).
  4. `--fixture pen_hover_to_contact` (ekranın ~%34/%19 noktasında tek küçük iz; basınç 288/65535 ile başlar) ve `--fixture pen_eraser` (silgi ucu: Krita silgi olarak algılar). `--tap 2` (ekran merkezinde çift tık: merkezde bir kelime/öğe varsa TextEdit/Finder'da seçilir/açılır = clickState 2), `--tap 1` (tek tık).
  5. **Ctrl-C güvenliği:** `--stroke ramp --repeat 20 --countdown 3` çalışırken Ctrl-C: `interrupted: input released`, Krita'da takılı çizgi yok, fareyle normal tıklanır.
  6. **Ağ yolu:** `open build/MateBridge.app`, tableti bağla. Log: `ev=input_session_start`, `ev=input_gate accessibility=1 display=1`. `display=1` gelmiyorsa `input_display_missing displays=...` satırını bana ilet.
  7. **Koordinat:** tablette kalemle ekranın dört köşesine ve ortasına yaklaş: Mac imleci / Krita fırça çerçevesi tam aynı yere gider, köşelerde sanal ekranın köşesine oturur, dışına taşmaz.
  8. **Krita kalem:** basınç (hafif -> ince/saydam, sert -> kalın/opak), eğim, hover (çizmeden çerçeve izler), vuruş dokunulan yerde başlar ve kaldırılan yerde biter, hızlı çizgilerde kopma/uzayan çizgi yok. Silgi: M-Pencil çift dokunma -> silgi (Krita silgiye geçer), tekrar -> kalem.
  9. **Dokunma:** parmakla dokunma o noktaya tıklar; hızlı iki dokunma çift tıklamadır (Finder'da açar / TextEdit'te kelime seçer; olmazsa 12 pt mesafeyi not et); sürükleme sürükler; kalem menzildeyken avuç dokunuşu yok sayılır (1 sn kapı).
  10. **Menü:** Sistem Ayarları'ndan izni kapatıp aç ve menünün <= 1 sn içinde güncellendiğine bak.
  11. **Takılma testleri**, her birinde çizim sırasında tetikle; sonuç: çizim durur, Mac'te düğme basılı kalmaz (başka bir yere tıkla), log `ev=input_release cause=... events=N`:
      a. tablette uygulamayı arka plana at (`client_request_1`);
      b. tablette Wi-Fi'ı kapat / USB'yi çek (önce `silence` ~1,5 sn, sonra `timeout`);
      c. tablette uygulamayı zorla durdur (`disconnected`);
      d. çizerken tablette uygulamayı yeniden başlat = aynı cihaz devralma (`superseded`, sonra yeni oturum; yeni oturumda yarım kalmış eski vuruş çizim başlatmaz);
      e. Mac'te menüden Quit; ayrıca Terminal'den çalıştırıp Ctrl-C (`input_shutdown released=N`);
      f. kalem menzildeyken tablet ağı tıkanırsa (ör. Wi-Fi'ı kapat) kalem 500 ms watchdog'la ya da 1,5 sn sessizlikle Mac'te menzilden çıkar (Krita çerçevesi kaybolur).
  12. **İzin yarıda:** kalem menzildeyken Sistem Ayarları'ndan MateBridge'in Erişilebilirlik iznini kapat: <= 1 sn içinde menüde uyarı, imleç kalemi izlemez, çökme yok; izni geri aç: kalem sonraki hareketle yeniden görünür. (Çizim sırasında kapatma için "Bilinen sınırlar (a)".)
  13. **Sanal ekran yok:** tableti kapat, ekranın kalkmasını bekle (10 sn ekran süresi): log `ev=input_gate ... display=0`; ekran yokken kalem/dokunma girdisi gerçek ekranda hiçbir şey oynatmaz. Yeniden bağlanınca `display=1` ve kalem çalışır.
  Sonuçlar `docs/NOTES.md`'ye (orkestratör) yazılacak: Krita'da basınç/eğim/silgi, clickState, eğim yönü, `display=1` eşleşmesi.
- **Açık sorular:**
  - `Package.swift`'e bir `MateBridgeHostTests` hedefi (ya da `InputController`/poster mantığının Core'a taşınması) gerekir mi? Şimdi Host kabuğu birim testsiz; risk yukarıdaki canlı listeyle kapatıldı.
  - `VideoPipeline` ekran kimliğini `public var displayID` olarak açarsa (tek satır, dosyam dışında) `VirtualDisplayLocator`'ın vendor/model araması yerine kesin kimlik kullanılır ve sabitlerin kopyası kalkar.
  - `ReleaseCause`'a `.gateLost` (ekran/izin gitti) eklensin mi? Şimdilik `.disconnected`.
  - `InputController`'ın `SessionServer.queue` yerine kendi kuyruğunu kullanması kabul mü, yoksa `SessionServer`'a bir "oturum kuyruğunda çalıştır" kancası mı eklenmeli (dosya listesi dışı)?
  - `Geometry+Display.swift` bölünsün/yeniden adlandırılsın mı (ör. `Injection/` altında geometri + planlayıcı + pipeline)?
  - Scroll yönü/ölçeği/atalet ve klavye Faz 3'te; `KEY` hâlâ makinede yok.
  - İşaretçi düğmeleri için watchdog yok (T-022'den devir): takılan ama kalp atışı süren bir istemci bir düğmeyi basılı tutabilir. Orkestratör Faz 3'e ertelemişti.
