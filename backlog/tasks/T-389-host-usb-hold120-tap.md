---
id: T-389
title: Host — USB'de 120 Hz'i tut (MATEBRIDGE_HOLD120, periyodik adb tap)
status: todo
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

(boş; ajan doldurur ve önce commit eder)

## Handoff

## Open questions
