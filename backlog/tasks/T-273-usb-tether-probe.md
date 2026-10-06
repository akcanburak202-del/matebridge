---
id: T-273
title: Prob — USB tethering (NCM) adb ile başlatılabiliyor mu, uygulama Mac'e bu yoldan ulaşabiliyor mu
status: in-progress
phase: 6
owner: android-client-dev
depends_on: []
decisions: []
files:
  - probes/usb-tether-probe/
  - backlog/tasks/T-273-usb-tether-probe.md
---

## Amaç

NOTES 2026-10-06 ~14:40: `svc usb setFunctions ncm` ile tablet NCM'e geçiyor, Mac yerleşik sürücüyle arayüz açıyor (en8), ama uygulamalar `ncm0`'a yönlenemiyor (Android tethering başlatılmadıkça arayüz yerel ağa eklenmiyor) ve MRDI-W09'da USB paylaşımı arayüzü yok. Bu prob, tethering'i **adb kabuğu hesabıyla** (uid 2000; `TETHER_PRIVILEGED` izni var) başlatıp Mac ile tablet uygulaması arasında doğrudan TCP yolu kurulabildiğini sınar. Ürün koduna dokunulmaz. Amaç: adb tünelini veri yolundan çıkarmak (adb yalnız başlatıcı kalır; host zaten her takışta adb kullanıyor).

## Kabul

1. `probes/usb-tether-probe/`: tablette `app_process` ile kabuk hesabıyla çalışan küçük yardımcı (dex/jar; scrcpy'nin `CLASSPATH=... app_process` kalıbı): `start [usb|ncm]`, `stop`, `status`. `TetheringManager`/`ITetheringConnector`'a yansıtma ya da binder ile erişir (`TETHERING_USB` + `settings global tether_force_usb_functions=1`, ve ayrıca `TETHERING_NCM`); sonucu ve hata kodunu açıkça yazar. Mac tarafı: `run.sh` (push, çalıştır, durumu topla, geri al).
2. Cihazda sırayla ölç ve Handoff'a yaz:
   - tethering başladı mı (sonuç kodu, `dumpsys tethering` durumu, tablet `ncm0`/arayüz adresi);
   - Mac arayüzü ve DHCP IPv4 alıyor mu (`ifconfig`, `ipconfig getifaddr enX`); Mac'in varsayılan yolu ve internet hizmet sırası **değişmiyor mu** (Ethernet önde kalmalı);
   - **uygulama kimliğiyle** erişim: `run-as dev.matebridge.client` ile Mac'in bu arayüzdeki adresine TCP bağlantısı (ör. Mac'te geçici bir dinleyici; MateBridge host portlarına dokunma), RTT/yaklaşık gecikme ve kısa bir aktarım hızı (nc + zamanlama, ya da basit bir echo);
   - kablo çıkar/tak sonrası davranış (tethering kendiliğinden kapanıyor mu, yeniden başlatma süresi).
3. Her denemenin sonunda geri al: tethering durdur, `tether_force_usb_functions` sil, USB işlevi `hisuite,mtp,mass_storage,adb` (doğrula). Mac'te ağ hizmeti ayarı değiştirme (yönetici şifresi isteyen hiçbir şey yok).
4. Kural: tablet erişimi yalnız kablosuz adb ile (`adb -s 192.168.1.105:5555`; USB adb işlev değişince kopar). Bu prob çalışırken başka cihaz testi yok (orkestratör sağlar). MateBridge uygulamasını kaldırma/ayarlarını değiştirme; yalnız `run-as` ile ağ testi. Mac'te pencere açma.
5. Rapor: çalıştı mı, hangi yolla; engel neyse tam hata; ürüne alınırsa host'un her takışta ne yapacağı (komut dizisi, süre) ve tahmini iş.

## Plan

1. `probes/usb-tether-probe/`: tek Java dosyası (`TetherProbe.java`, paket `dev.matebridge.probe.usbtether`), `build.sh` ile `javac` (Android Studio JBR) + `d8` → `build/usb-tether-probe.jar` (Gradle yok; `check.sh` bu dizini derlemez, `build.sh` ayrı çalışır). Tablette `CLASSPATH=… app_process / dev.matebridge.probe.usbtether.TetherProbe <komut>`.
   - `info`: `ITetheringConnector` vekil yöntemleri + `TetheringRequestParcel` alanları (Huawei imza farkı var mı).
   - `start usb|ncm`, `stop usb|ncm`, `stopall`, `legacy-usb on|off`, `tether <iface>`, `untether <iface>`: `ServiceManager.getService("tethering")` → `ITetheringConnector.Stub.asInterface` (yansıtma); sonuç `IIntResultListener` üzerinden ham `Binder` ile alınır, kod + ad (`TETHER_ERROR_*`) yazılır.
   - `rtt <host> <port> <n>` ve `tput <host> <port> <sn>`: aynı jar `run-as dev.matebridge.client` altında (uygulama uid'i) TCP yankı RTT'si (min/p50/p99/max) ve tek yön aktarım hızı ölçer (tablette `nc` yok).
2. `mac_server.py`: Mac'te geçici yankı (47900) ve havuz (47901) dinleyicisi; yalnız tether arayüz adresine bağlanır, MateBridge portlarına dokunmaz.
3. `run.sh`: `build`, `push`, `start <usb|ncm|rndis>`, `status`, `mac`, `measure`, `restore` alt komutları; `restore` her zaman tethering durdurur, `tether_force_usb_functions` siler, USB işlevini `hisuite,mtp,mass_storage,adb` yapar ve doğrular (`trap` ile hata durumunda da).
4. Cihazda sıra: (a) NCM zorlamalı `TETHERING_USB`, (b) `TETHERING_NCM`, (c) gerekirse eski `setUsbTethering`/`tether ncm0`, (d) karşılaştırma için RNDIS. Her birinde Mac `ifconfig`/`ipconfig getifaddr`/varsayılan yol/hizmet sırası; çalışan yolda uygulama uid'i ile RTT/aktarım, sonra kablo çık/tak (kullanıcı gerektirir; olmazsa yazılır). Her deneme sonunda geri al.

## Handoff

## Open questions
