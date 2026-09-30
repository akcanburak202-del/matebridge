---
id: T-039
title: Mac günlük kullanım — oturum açılışında başlama, menü (durum, loglar), USB tünellerini kendiliğinden kurma
status: review
phase: 4
owner: mac-host-dev
depends_on: [T-020]
decisions: []
files:
  - host-mac/Sources/MateBridgeApp/
  - host-mac/Sources/MateBridgeHost/Session/
  - host-mac/Sources/MateBridgeHost/Usb/
  - host-mac/Sources/MateBridgeCore/Usb/
  - host-mac/Tests/MateBridgeCoreTests/
  - scripts/usb-mode.sh
  - scripts/bundle-host.sh
  - backlog/tasks/T-039-host-daily-use.md
---

## Amaç

PLAN Aşama 4: Mac tarafında "hiçbir şey yapmadan çalışsın". Bugün host elle açılıyor (`open build/MateBridge.app`), USB modu için `scripts/usb-mode.sh on` elle çalıştırılıyor ve kablo çekilip takılınca tüneller geri gelmiyor (NOTES 2026-09-30). Mac açılışta otomatik oturum açıyor (FileVault kapalı).

## Kabul kriterleri

- [ ] **Oturum açılışında başlama:** menüde "Oturum açılışında başlat" (onay işaretli) → `SMAppService.mainApp.register()/unregister()`; durum menü açılırken okunur; hata olursa menüde tek satır ve log. Varsayılan: **açık** (ilk açılışta bir kez kaydeder; kullanıcı kapatırsa bir daha zorlamaz, tercih `UserDefaults`'ta).
- [ ] **Menü:** durum satırı bağlı tablet adını ve taşımayı gösterir (ör. "Bağlı: MatePad (USB)" / "Bekleniyor"); "Logları aç" → `~/Library/Logs/MateBridge/` Finder'da; "USB modu" onay öğesi (aşağıda). Mevcut öğeler (izin, onaylı cihazları unut, Quit) kalır.
- [ ] **USB tünel bekçisi** (`MateBridgeHost/Usb/`, saf karar mantığı `MateBridgeCore/Usb/` ve testli): "USB modu" açıkken host `adb`'yi bulur (`ANDROID_HOME`, `~/Library/Android/sdk/platform-tools/adb`, `PATH`), adb sunucusunun ayakta olduğunu sağlar (bugünkü betikteki launchd yöntemi: `launchctl submit -l dev.matebridge.adb` ile `ADB_MDNS=0 ADB_MDNS_AUTO_CONNECT=0 adb nodaemon server`, `-a` olmadan) ve cihaz bağlıyken `adb reverse tcp:47001 tcp:47001` + `tcp:47002` tünellerinin var olduğunu **2 sn'de bir** denetler; yoksa kurar. Kablo çekilip takılınca tüneller en geç birkaç saniyede geri gelir. Yalnızca durum değişimi loglanır (`ev=usb_tunnel state=up|down|no_device|no_adb`), cihaz seri numarası **loglanmaz**. Alt süreçler zaman aşımıyla çalışır (asılı kalan adb host'u kilitlemez), ana iş parçacığında çalışmaz. USB modu kapatılınca tüneller kaldırılır, bekçi durur. Tercih kalıcıdır; varsayılan **açık**.
- [ ] `scripts/usb-mode.sh` kalır (elle kullanım ve hata ayıklama için); başına "host artık bunu kendisi yapıyor" notu.
- [ ] `./scripts/check.sh` geçiyor; saf bekçi mantığı (durum → eylem: sunucu yok/cihaz yok/tünel eksik/tamam; geri çekilme) birim testli.

## Kapsam dışı

- Mac uyku/kilit/uyanma sonrası toparlanma (ayrı kart, önce ölçüm). Ayarlar ekranı, şifreleme.
- Gerçek olay gönderme yok. `adb` komutlarını **çalıştırma** (kullanıcının tableti bağlı; cihaz testi orkestratörde): kodu yaz, test et, çalıştırma.

## Plan

1. **Core/Usb (saf, testli):** `AdbOutput` (`adb devices` / `reverse --list` ayrıştırma, cihaz seçimi), `AdbLocator` (adb aday yolları: ANDROID_HOME, SDK varsayılanı, PATH, Homebrew), `UsbTunnelPlanner` (snapshot → durum + eylem: sunucu yok → startServer, cihaz yok → bekle, tünel eksik → installTunnels, tamam → none; durum değişimi dedup'u; 2 sn → 30 sn geri çekilme), `SessionTransport.classify` (loopback eş → USB).
2. **Host/Usb:** `UsbTunnelWatcher` kendi DispatchQueue'sunda, tick'ler seri ve `asyncAfter` ile zincirli (çakışmaz). Sunucu ayakta mı: 127.0.0.1:5037'ye TCP bağlantı denemesi (adb'yi yanlışlıkla kendiliğinden başlatmamak için); yoksa `launchctl remove` + `launchctl submit` (betikteki yöntem). Tüm alt süreçler zaman aşımlı (`ProcessRunner`, süre dolunca terminate/kill). Kapatılınca tünelleri `reverse --remove` ile kaldırır; adb sunucusuna dokunmaz. Yalnız durum değişimi loglanır (`component=usb`), seri numarası loglanmaz.
3. **Session:** `SessionServerState.connected` taşıma (usb/network) bilgisini de taşır (kontrol bağlantısının eş adresi loopback mı).
4. **Uygulama:** `LoginItem` (SMAppService.mainApp, ilk açılışta bir kez kayıt, tercih UserDefaults), menüde "Oturum açılışında başlat", "USB modu" (onay işaretli, varsayılan açık), "Logları aç", durum satırı "Bağlı: ad (USB)". Durum menü açılırken okunur.
5. `usb-mode.sh` başına not; `bundle-host.sh` değişmez (gerekmedikçe).

## Handoff

- **Commit:** son commit (SHA orkestratöre raporda; `git log task/T-039-host-daily-use`)
- **Dokunulan dosyalar:** Core/Usb/{AdbOutput,UsbTunnelPlanner}.swift, Tests/.../Usb/*, Host/Usb/{ProcessRunner,UsbTunnelWatcher}.swift, Host/Session/{HostLog,SessionServer}.swift (durum `.connected(deviceName:transport:)`), App/{main,LoginItem}.swift, scripts/usb-mode.sh (not), bu kart. `bundle-host.sh` değişmedi.
- **Varsayımlar:** Sunucu ayakta mı testi 127.0.0.1:5037 TCP bağlantısı (adb'yi kazara kendiliğinden başlatmamak için); `adb devices` cevap vermezse sunucu "down" sayılıp launchd işi silinip yeniden submit edilir. Kapatınca yalnız tüneller kaldırılır, adb sunucusu ve launchd işi kalır; uygulamadan çıkınca (Quit) tüneller yerinde bırakılır; bu bilinçli (zararsız, asenkron kaldırma çıkışa yetişmez). adb sunucusu `-a` OLMADAN başlatılır (yalnız loopback; `AdbServerLaunch` + test). USB taşıması = kontrol bağlantısının eşi loopback. Oturum açılışı ilk açılışta bir kez `register()` (UserDefaults `loginItemFirstRunDone`), sonra yalnız menü değiştirir. Tek cihaz: birden çok hazır cihazda gerçek (emulator olmayan) ilki seçilir.
- **Test edilmeyenler / cihazda doğrulanacaklar:** Hiçbiri çalıştırılmadı (adb/uygulama yok; yalnız saf mantık testli). (1) `SMAppService.mainApp.register()` Apple Development imzalı `build/MateBridge.app` ile: durum `.enabled` mı `.requiresApproval` mı, Sistem Ayarları > Giriş Öğeleri'nde görünüyor mu, yeniden başlatmada açılıyor mu. Uygulama /Applications dışında (build/) ise macOS kaydı reddedebilir ya da onay isteyebilir. (2) Watcher: gerçek adb ile tünellerin 2-4 sn içinde kurulması, kablo çek-tak, `launchctl submit` uygulamanın alt süreci olarak sandbox/TCC sorunu çıkarıyor mu, login item olarak açılınca adb yolu (PATH asgari; ANDROID_HOME/SDK yolu bakılır). (3) Yeni MateBridge menü öğeleri ve "Bağlı: ad (USB)". (4) `usb-mode.sh` ile çakışma: ikisi de aynı launchd etiketini kullanır.
- **Açık sorular:** Quit'te tünelleri kaldıralım mı (şu an hayır; asenkron kuyrukta yapılır, çıkışa yetişmez). Kapatmada tünel kaldırma hatası: 5 denemeye kadar geri çekilmeyle tekrarlanır, sonunda `state=remove_failed` loglanır (cihazda denenmedi). Yakalanan çıktı 64 KiB ile sınırlı (stdout+stderr tek boru); kesilmiş çıktı başarısız yoklama sayılır.
