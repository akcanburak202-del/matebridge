---
id: T-023
title: Mac girdi enjeksiyonu — CGEvent kalem/fare, koordinat dönüşümü, oturuma bağlama
status: in-progress
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

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
