---
id: T-389
title: Host — USB'de 120 Hz'i tut (MATEBRIDGE_HOLD120, periyodik adb tap)
status: review
phase: 7
owner: mac-host-dev
depends_on: [T-039, T-325]
decisions: [0044, 0016]
files:
  - host-mac/Sources/MateBridgeCore/Usb/
  - host-mac/Sources/MateBridgeCore/Session/TransportKnobs.swift
  - host-mac/Sources/MateBridgeHost/Usb/
  - host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift
  - host-mac/Tests/
  - docs/KNOBS.md
  - docs/LOGGING.md
  - backlog/tasks/T-389-host-usb-hold120-tap.md
---

## Amaç

Karar 0044, host tarafı. `MATEBRIDGE_HOLD120=1` açıkken ve koşullar sağlandıkça host tablete yaklaşık 1 sn'de bir `adb -s <seri> shell input touchscreen tap 2 2` gönderir. Huawei AGP bu dokunmayı görünce paneli 120 Hz'te tutar. İstemcinin bu dokunmayı yutması T-390'da.

## Kabul

1. **Anahtar:** `MATEBRIDGE_HOLD120` yalnız `1` iken açık, başka her değerde kapalı. `TransportKnobs.swift` içinde `WifiAdaptKnob` düzeninde (`Hold120Knob`). `docs/KNOBS.md`'de yeni satır.
2. **Koşullar:** dokunma ancak hepsi doğruyken gönderilir:
   - anahtar açık;
   - USB tüneli kurulu ve cihaz seri numarası biliniyor (`UsbTunnelWatcher` durumundan);
   - oturumun taşıması USB (uzak/Wi-Fi değil);
   - video akıyor (son kareler gönderiliyor ya da video bağlı);
   - Oyun ekranı etkin;
   - akış/hedef fps 120.

   Biri bozulunca zamanlayıcı hemen durur.
3. **Gerçek girdi beklemesi:** tabletten son 1,5 sn içinde dokunma, kalem ya da işaretçi (touchpad/fare) mesajı geldiyse dokunma o tur atlanır. Saf bir planlayıcı (`MateBridgeCore/Usb/` altında, ör. `Hold120Planner`) "şimdi dokun / bekle / kapalı" kararını zaman ve durum girdileriyle verir. Birim testli.
4. **Komut:** yalnız `input touchscreen tap 2 2`. `motionevent DOWN/UP` ya da `swipe` yok. Komut `UsbTunnelWatcher`'ın kullandığı adb ikilisi ve ortamıyla, sınırlı süreyle (ör. 2 sn) çalışır. Asılı kalan ya da hata veren çağrı bir sonrakini engellemez: aynı anda en çok bir çağrı. Ardışık hatalarda geri çekilme (ör. 1→2→5 sn, başarıda sıfırlanır).
5. **Kuyruk:** iş, mevcut USB kuyruğunu ya da kendi seri kuyruğunu kullanır. Ana iş parçacığını, video ya da girdi yolunu asla bloklamaz.
6. **Loglar** (`docs/LOGGING.md`):
   - `ev=hold120 state=on|off reason=<ilk bozulan koşul>`, yalnız durum değişince;
   - `ev=hold120_stats taps= skipped_input= failures=`, en çok 30 sn'de bir, yalnız açıkken.

   Seri numarası, koordinat dışında girdi içeriği ve tuş bilgisi loglanmaz.
7. Anahtar kapalıyken davranış bayt bayt aynı: zamanlayıcı yok, adb çağrısı yok.
8. `./scripts/check.sh` geçer. Cihazda deneme bu kartta YOK; orkestratör yapar. Mac'te pencere açma (AGENTS / bellek: Mac'in tek ekranı tablet).

## Plan

Saf mantik `MateBridgeCore`, adb/zamanlayici `MateBridgeHost`; main.swift dokunulmaz (kart dosya listesinde yok), baglanti `StreamCoordinator` icinden.

1. `TransportKnobs.swift`: `Hold120Knob` (`MATEBRIDGE_HOLD120`, yalniz `1`), `WifiAdaptKnob` duzeninde.
2. `Core/Usb/Hold120Planner.swift` (saf, saat girdili):
   - `Hold120Conditions` (tunel+seri, usb tasimasi, video, oyun ekrani, 120 fps) ve `firstBroken` -> `Hold120Reason` (log `reason=`).
   - `Hold120Planner.decide(now:conditions:lastInputUs:)` -> `.off(reason)` / `.wait(until)` / `.skipInput` / `.tap`. Aralik 1 sn, gercek girdi sessizligi 1,5 sn, ayni anda en cok bir cagri (in-flight), ardisik hata geri cekilmesi 1->2->5 sn (basarida sifirlanir), durum degisimi (`stateChange`) ve 30 sn stats penceresi. `Hold120Input.counts(MessageType)`: pen, pointerRel, pointerAbs, scroll, penGesture, pinch, padSwipe (tus ve diger mesajlar sayilmaz).
3. `Host/Usb/UsbDeviceRegistry.swift`: kilitli, `UsbTunnelWatcher.tick` tunel `up` iken seriyi yayinlar, aksi halde/devre disi iken siler; tek gozlemci geri cagrisi. `UsbTunnelWatcher.swift` kucuk degisiklik.
4. `Host/Usb/Hold120Tap.swift`: `Hold120Controller` (kendi seri kuyrugu + ayri adb kuyrugu, ana is parcacigi/video/girdi yolu yok). `updateConditions` (esitse yok sayar), `noteInput()` (kilitli zaman damgasi, sicak yol), zamanlayici yalniz kosullar saglanirken calisir. Komut yalniz `adb -s <seri> shell input touchscreen tap 2 2`, `ProcessRunner` + `AdbBinary.environment`, 2 sn zaman asimi, adb sunucusu kapaliysa cagri yok (basarisiz sayilir). Loglar `usb` bileseni, `ev=hold120`, `ev=hold120_stats`.
5. `StreamCoordinator`: anahtar aciksa denetleyici olusturulur (kapaliyken nil -> sifir fark); `deliver` icinde `noteInput`; `handle` sonunda kosullar (`session.transport == .usb`, `consumer == .sender`, `!settings.displayHiDPI`, `settings.fps == 120`) itilir; `onShutdown`'da durdurulur.
6. Testler: knob, planner (kosullar, ilk bozulan neden, girdi atlama, aralik, in-flight, geri cekilme, stats, durum degisimi), `Hold120Input`.
7. `docs/KNOBS.md` satir 50, `docs/LOGGING.md` bolumu.

## Handoff

- **Branch:** `task/T-389-hold120` (plan commit 4883e338, then the implementation commit; SHA in the final report). `./scripts/check.sh`: ALL OK (1300 Swift tests, 21 new in `Hold120PlannerTests`).
- **Files:** `MateBridgeCore/Usb/Hold120Planner.swift` (new: `Hold120Reason`, `Hold120Conditions`, `Hold120Input`, `Hold120Planner`), `MateBridgeCore/Session/TransportKnobs.swift` (`Hold120Knob`), `MateBridgeHost/Usb/Hold120Tap.swift` (new: `Hold120Controller`), `MateBridgeHost/Usb/UsbDeviceRegistry.swift` (new), `MateBridgeHost/Usb/UsbTunnelWatcher.swift` (publishes serial), `MateBridgeHost/Session/StreamCoordinator.swift`, `Tests/MateBridgeCoreTests/Usb/Hold120PlannerTests.swift`, `docs/KNOBS.md` (row 50), `docs/LOGGING.md`, this card. Task branch was fast-forwarded to `main` first (the card and 0044 were committed after the worktree base).
- **Design:** the knob off -> `StreamCoordinator.hold120 == nil`: no controller, timer, registry observer or adb call; `deliver` and `handle` only add a nil check. On: `refreshHold120()` runs after every coordinator event and pushes session facts (`session.transport == .usb`, a `.sender` consumer, `!settings.displayHiDPI` = game display, `settings.fps == 120`). The device condition comes from the new `UsbDeviceRegistry`, which `UsbTunnelWatcher.tick` fills with the serial only while its state is `.up` (and clears on disable); `main.swift` is outside the card's files, so the controller is wired through the coordinator and the registry instead of the app. Real input: `deliver` stamps a lock-protected time for pen, pointerRel, pointerAbs, scroll, penGesture, pinch, padSwipe (type only; keys do not count). Timer exists only while on and no tap runs; adb runs on its own queue with a 2 s `ProcessRunner` deadline, `-s <serial> shell input touchscreen tap 2 2` only. No tap if the adb server does not answer on loopback (counts as a failure; the hold never starts a server).
- **Assumptions:** "Oyun ekranı etkin" = the 1x game display (decision 0029) is in use, not just a stream mode. `deviceKnown` also means the watcher state is `up` (device present and all tunnels installed). Stats are cumulative totals since the controller started. Tap spacing is measured from tap completion. `reason=not_usb` also covers "no session". The hold's first tap happens immediately when conditions become true.
- **Not tested / needs the real tablet (orchestrator):** the tap itself (the client swallowing it is T-390, install the client first); that the real `input touchscreen tap 2 2` keeps the panel at 120 Hz over many minutes; the 1.5 s input wait vs lost real touches/pen; heat/battery; behavior when the cable is unplugged mid-session (the watcher notices through IOKit, then the next tap fails and backs off); `ev=hold120` / `ev=hold120_stats` lines in the real log.

## Open questions

- Not blocking: `ev=profile knobs=` (`StreamProfileLog.knobAllowList`) does not list `MATEBRIDGE_HOLD120` (that file is outside this card's files; KNOBS row says so). Add it later if the knob is kept.
