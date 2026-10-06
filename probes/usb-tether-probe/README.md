# usb-tether-probe (T-273)

Soru: USB tethering (NCM) adb kabuk hesabıyla başlatılıp MateBridge uygulaması Mac'e bu arayüzden doğrudan TCP ile ulaşabilir mi?

**Sonuç (2026-10-06): hayır.** Tethering servisi kabuk hesabıyla sürülebiliyor (`TETHER_PRIVILEGED` yeterli), ama MRDI-W09'un tethering yapılandırmasında NCM arayüz deseni boş (`tetherableNcmRegexs: []`, USB desenleri `usb\d, rndis\d`), çekirdek ise arayüzü `ncm0` adıyla açıyor → `ncm0 is not a tetherable iface` / `could not enable IpServer for function NCM`. RNDIS tethering tablette çalışıyor ama macOS'ta RNDIS sürücüsü yok. Ayrıntı: kartın Handoff bölümü.

## Parçalar

- `src/…/TetherProbe.java`: `app_process` ile çalışan yardımcı. `ITetheringConnector`'a yansıtma ile erişir; sonuç `IIntResultListener` yerine ham `Binder` ile alınır. Komutlar: `info`, `start usb|ncm|ethernet [global|local]`, `stop …`, `stopall`, `legacy-usb on|off`, `tether|untether IFACE`, `rtt HOST PORT N`, `tput HOST PORT SN` (tablette `nc` yok).
- `mac_server.py`: Mac'te geçici yankı (47900) + havuz (47901) dinleyicisi; yalnız verilen adrese bağlanır, MateBridge portlarını reddeder.
- `run.sh`: `build | push | tp … | app … | status | mac | try MODE | measure [IP] | restore`. `try` her durumda `restore` ile biter (tethering durdur, `tether_force_usb_functions` sil, USB `hisuite,mtp,mass_storage,adb` doğrula). adb USB işlevi değişince yeniden başladığı için kablosuz bağlantı otomatik yeniden kurulur.
- `build.sh`: Gradle yok; JBR `javac` + `d8` → `build/usb-tether-probe.jar`, ayrıca host JVM'de `StatsTest`. `scripts/check.sh` bu dizini derlemez (Gradle/SwiftPM projesi değil).

```bash
probes/usb-tether-probe/run.sh build && probes/usb-tether-probe/run.sh push
probes/usb-tether-probe/run.sh try usb-ncm     # ya da ncm, legacy-ncm, tether-ncm0, usb-rndis
probes/usb-tether-probe/run.sh measure 192.168.1.106   # Wi-Fi karşılaştırması (Mac LAN adresi)
```

Yalnız kablosuz adb (`DEV=192.168.1.105:5555`); USB adb işlev değişince kopar.
