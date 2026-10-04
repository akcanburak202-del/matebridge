---
id: T-228
title: Host — the USB tunnel watcher must ignore network adb devices (adb over Wi-Fi is not USB)
status: review
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

- [x] [XCTest] `selectDevice`: seri numarası ağ adresi biçiminde olan (`host:port`, `adb-…._adb-tls-connect._tcp` mDNS biçimi) cihazlar seçilmez; yalnız USB cihazı varsa o seçilir; yalnız ağ cihazı varsa `nil` (tünel yok). `adb devices -l` çıktısındaki `usb:` alanı varsa onu tercih eden kural da kabul (planda seç).
- [x] [XCTest] Mevcut `emulator-` kuralı ve çoklu cihaz sırası değişmez.
- [ ] [device] Kablosuz adb bağlıyken ve kablo takılı değilken `adb reverse --list` boş kalır; kablo takılınca tünel USB cihazına kurulur.
- Seri numarası loglanmaz (mevcut kural).

## Plan

- **Kural seçimi: seri numarası biçimi** (`usb:` alanı değil). `UsbTunnelWatcher` ve `TabletFilesBridge` `adb devices` çağırıyor (`-l` yok) ve ikisi de kartın `files:` listesinde değil; `usb:` kuralı bu çağrıları değiştirmeyi gerektirir. Seri biçimi bugünkü çıktıyla çalışır.
- `AdbDevice.isNetwork` (MateBridgeCore): seri `:` içeriyorsa (`192.168.1.105:5555`, `[fe80::1]:5555`, `host:port`) ya da mDNS hizmet adıysa (`._adb-tls-connect._tcp`, `._adb._tcp` gibi `._tcp` içeren; sondaki `.` dahil) ağ cihazıdır. USB seri numaraları bunları içermez.
- `AdbOutput.selectDevice`: hazır cihazlardan ağ cihazlarını at; kalanlarda mevcut sıra aynen kalır (ilk fiziksel, yoksa `emulator-`). Yalnız ağ cihazı varsa `nil` → planner `no_device`, tünel kurulmaz.
- Yan etki (bilinçli): `TabletFilesBridge` de `selectDevice` kullanıyor, artık ağ adb'sine `adb forward` kurmaz (WebDAV zaten yalnız USB oturumunda çalışıyor).
- XCTest (`AdbOutputTests`): IP:port, IPv6, mDNS biçimleri seçilmez; USB+ağ karışık listede USB seçilir (sıra fark etmeksizin); yalnız ağ → `nil`; ağ + emulator → emulator; mevcut emulator/offline testleri değişmeden geçer; `parseDevices` mDNS satırını doğru ayrıştırır.
- `docs/LOGGING.md`: `usb_tunnel state=no_device` satırının ağ adb cihazlarını saymadığını not et (yeni log alanı yok; seri loglanmaz).
- Sınır: düzeltmeden önce ağ bağlantısına kurulmuş eski `adb reverse` tünelleri bu değişiklikle silinmez (watcher artık o seriyi görmez); cihazda bir kez `adb -s <ip:port> reverse --remove-all` ya da `adb disconnect` gerekir.

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:** `4b4daf5` (plan: `1c8e1c5`), dal `task/T-228-usb-watcher-skip-network-adb`.
- **Dokunulan dosyalar:** `host-mac/Sources/MateBridgeCore/Usb/AdbOutput.swift` (`AdbDevice.isNetwork`, `selectDevice` ağ cihazlarını atar), `host-mac/Tests/MateBridgeCoreTests/Usb/AdbOutputTests.swift` (4 yeni test), `docs/LOGGING.md` (yeni "USB tünel bekçisi" bölümü; `usb_tunnel` olayı daha önce belgelenmemişti), bu kart.
- **Varsayımlar:** Kural seri biçimine dayanır: `:` içeren (IPv4/IPv6/ad `host:port`) ya da `._tcp` içeren (mDNS `._adb-tls-connect._tcp`, `._adb._tcp`) seri ağdır. USB iSerial'inde bunların olmadığı varsayıldı (Huawei seri numarası alfanümerik). `usb:` alanı kuralı seçilmedi, çünkü `adb devices -l` çağrısı kart dışındaki `UsbTunnelWatcher`/`TabletFilesBridge`'de. `TabletFilesBridge` de `selectDevice` kullandığından WebDAV `adb forward` artık ağ adb'sine kurulmaz (WebDAV zaten yalnız USB oturumunda çalışıyor). `check.sh`: ALL OK.
- **Test edilmeyenler / cihazda doğrulananlar:** [device] kriteri test edilmedi (host yeniden başlatılmadı, tablete dokunulmadı). Orkestratör: (1) yeni host'u başlatmadan önce eski ağ tünelini temizle: `adb -s 192.168.1.105:5555 reverse --remove-all` (bu değişiklik, düzeltmeden önce kurulmuş tünelleri silmez; watcher o seriyi artık hiç görmez); (2) kablosuz adb bağlı, kablo yokken birkaç saniye sonra `adb -s 192.168.1.105:5555 reverse --list` boş, host logunda `usb ev=usb_tunnel state=no_device`; (3) kablo takılınca tünel USB serisine kurulur (`adb -s <usb-seri> reverse --list` 47001/47002), `state=up`; (4) Otomatik modda tablet Wi-Fi'de kalmalı (127.0.0.1:47001 kablo yokken kapalı).
- **Açık sorular:** Bekçi kapatılınca (`startRemoval`) ya da yükseltmeden kalan ağ cihazı üzerindeki eski tüneller otomatik silinmiyor; istenirse ayrı kartla `UsbTunnelWatcher` ağ serilerindeki 47001/47002 tünellerini bir kez kaldırabilir (kart dışı dosya).
