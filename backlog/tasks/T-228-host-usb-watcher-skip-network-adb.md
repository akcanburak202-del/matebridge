---
id: T-228
title: Host — the USB tunnel watcher must ignore network adb devices (adb over Wi-Fi is not USB)
status: todo
phase: 6
owner: mac-host-dev
depends_on: []
decisions: []
files:
  - host-mac/Sources/MateBridgeCore/Usb/AdbOutput.swift
  - host-mac/Tests/MateBridgeCoreTests/Usb/
  - docs/LOGGING.md
  - backlog/tasks/T-228-host-usb-watcher-skip-network-adb.md
---

## Amaç

Cihaz 2026-10-04 ~22:40: tablette kablosuz adb açıldı (`adb tcpip 5555` + `adb connect 192.168.1.105:5555`). Host'un `UsbTunnelWatcher`'ı `AdbOutput.selectDevice` ile ilk hazır cihazı seçiyor (`AdbOutput.swift:68-71`, yalnız `emulator-` atlanıyor) ve `adb reverse tcp:47001/47002` tünellerini **ağ üzerinden adb bağlantısına** kurdu (`adb reverse --list` → `host-15 tcp:47001 tcp:47001`). Tablet "Otomatik" bağlantıdaysa 127.0.0.1:47001 açık göründüğü için bunu USB sanıp görüntüyü adb'nin Wi-Fi tüneline sokabilir: hem daha kötü (adb tüneli + Wi-Fi) hem de Wi-Fi ölçümlerini bozar. Ölçümde tablet bağlantısı elle "Wi-Fi"ye sabitlenerek önlendi.

## Kabul kriterleri

- [ ] [XCTest] `selectDevice`: seri numarası ağ adresi biçiminde olan (`host:port`, `adb-…._adb-tls-connect._tcp` mDNS biçimi) cihazlar seçilmez; yalnız USB cihazı varsa o seçilir; yalnız ağ cihazı varsa `nil` (tünel yok). `adb devices -l` çıktısındaki `usb:` alanı varsa onu tercih eden kural da kabul (planda seç).
- [ ] [XCTest] Mevcut `emulator-` kuralı ve çoklu cihaz sırası değişmez.
- [ ] [device] Kablosuz adb bağlıyken ve kablo takılı değilken `adb reverse --list` boş kalır; kablo takılınca tünel USB cihazına kurulur.
- Seri numarası loglanmaz (mevcut kural).

## Plan

_(Ajan kodlamadan önce doldurur.)_

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulananlar:**
- **Açık sorular:**
