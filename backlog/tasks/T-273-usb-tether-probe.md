---
id: T-273
title: Prob — USB tethering (NCM) adb ile başlatılabiliyor mu, uygulama Mac'e bu yoldan ulaşabiliyor mu
status: review
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

**Sonuç: çalışmadı.** Tethering adb kabuk hesabıyla başlatılabiliyor, ama hiçbir yol Mac'te IP alan, uygulamanın ulaşabildiği bir arayüz üretmiyor. Engel cihaz yapılandırması: `tetherableNcmRegexs: []` ve USB deseni `[usb\d, rndis\d]`, NCM işlevinin arayüzü ise `ncm0` → Tethering `ncm0`'ı tanımıyor. RNDIS tethering tablette çalışıyor, ama macOS'ta RNDIS sürücüsü yok.

- Commit: uygulama `3d5a4ccc` (bu Handoff ayrı bir commit'te). Dal: `task/T-273-usb-tether-probe`.
- Dosyalar: `probes/usb-tether-probe/{README.md, build.sh, run.sh, mac_server.py, src/dev/matebridge/probe/usbtether/{TetherProbe,Stats}.java, test/dev/matebridge/probe/usbtether/StatsTest.java}`, bu kart.

### Ölçümler (2026-10-06 14:47–14:53, yalnız kablosuz adb)

| Deneme | Çağrı sonucu | Tablet | Mac |
|---|---|---|---|
| `startTethering(USB)`, `exemptFromEntitlementCheck=true` | `14 NO_CHANGE_TETHERING_PERMISSION` (bu bayrak NETWORK_STACK ister; kabukta yok) | değişiklik yok | — |
| `try usb-ncm`: `tether_force_usb_functions=1` + `startTethering(USB)`, exempt=false | `0 NO_ERROR` | `mUsbTetheringFunction: NCM`, USB `ncm,adb`, `ncm0` UP, Huawei'nin kendi 192.168.66.x/24 adresi (her seferinde farklı). Log: `ncm0 is not a tetherable iface, ignoring` + `ERROR could not enable IpServer for function NCM`. Tether state'te `ncm0` yok | en8 (MRDI-W09, CDC-NCM) UP/active, `ipconfig getifaddr en8` boş (DHCP yok), yalnız IPv6 link-local |
| `try ncm`: `svc usb setFunctions ncm` + `startTethering(NCM)` | `0` | aynı: `ncm0 is not a tetherable iface` | aynı, IPv4 yok |
| `try legacy-ncm`: force=1 + `setUsbTethering(true)` | `0` | aynı: `could not enable IpServer for function NCM` | aynı |
| `tether("ncm0")` (NCM etkinken) | `1 UNKNOWN_IFACE` | — | — |
| `startTethering(ETHERNET)` (NCM etkinken) | `0` | hiçbir şey olmuyor (eth arayüzü yok) | — |
| `setUsbTethering(true)` force olmadan (RNDIS) | `0` | **çalıştı**: USB `rndis,adb`, `rndis0 - TetheredState`, 192.168.42.129/24, upstream `wlan0` | IOUSB'de `MRDI-W09` aygıtı var, ağ arayüzü **yok** (macOS RNDIS sürücüsü yok) |

- **Uygulama uid erişimi** (NCM etkinken, `run-as dev.matebridge.client` + `app_process`): Mac en8 link-local adresine TCP → `ENETUNREACH (Network is unreachable)`. Kabuk uid'i de aynı. `ip rule` içinde `ncm0` geçen kural yok; `ncm0` yalnız `main` tablosunda (IPv4 /24) ve tablo 1019'da (IPv6 fe80::/64) → netd ilke yönlendirmesi uygulamaları oraya göndermiyor (NOTES 14:40 bulgusu doğrulandı).
- **Tether üzerinden RTT / aktarım: ölçülemedi** (yol yok). Aynı araçla Wi-Fi karşılaştırması (uygulama uid'i → Mac 192.168.1.x, 47900/47901): RTT n=500 min 10.8 / p50 12.6 / p99 15.3 / max 18.3 ms (64 B ping-pong); tek yön aktarım 5 s'de 731 Mbit/s (Mac havuzu aynı sayıyı doğruladı). Kabuk uid RTT p50 12.9 ms.
- **Mac:** varsayılan yol her adımda `en0`; hizmet sırası değişmedi: (1) Ethernet (2) MRDI-W09 (3) Thunderbolt Bridge (4) Wi-Fi. (MRDI-W09 hizmeti 14:40 deneyinden kalma; bu probda oluşmadı, ona dokunulmadı.) Mac'te hiçbir ayar değişmedi, pencere açılmadı, dinleyici kalmadı.
- **Kablo çıkar/tak:** denenmedi; çalışan bir yol olmadığından anlamsız ve kullanıcı gerektirir.
- **Geri alma:** her denemeden sonra `RESTORE OK: usb=hisuite,mtp,mass_storage,adb tether_force_usb_functions=null`; son doğrulama 14:53: `sys.usb.config=hisuite,mtp,mass_storage,adb`, `tether_force_usb_functions=null`, Tether state yalnız `p2p0`/`wlan0` Available. Tablet geçici dosyaları (`/data/local/tmp` jar + betikler, uygulama `cache/` jar) silindi. MateBridge uygulamasına/ayarlarına dokunulmadı.
- `./scripts/check.sh`: ALL OK (probe dizinini derlemez; `build.sh` + `StatsTest` ayrıca geçti).
- Yan etki: USB işlevi her değiştiğinde adbd yeniden başlıyor; USB adb ve **kablosuz adb bağlantısı da kopuyor** (`run.sh` otomatik yeniden bağlanıyor). MateBridge USB oturumu 14:48–14:53 arasında birkaç kez kesilmiş olabilir.

### Ürüne alınırsa

Alınamaz. Gerekenler kabuk yetkisini aşıyor: Tethering kaynak katmanında `config_tether_ncm_regexs`/`config_tether_usb_regexs` değişikliği (sistem/overlay, root) ya da arayüz yeniden adlandırma (`NET_ADMIN`); RNDIS yolu için Mac'e üçüncü taraf DriverKit RNDIS sürücüsü (yeni bağımlılık, imzalama, kullanıcı onayı) gerekir. `TestNetworkManager.setupTestNetwork` yalnız `testtun`/`ipsec` önekli arayüz kabul ediyor (denenmedi, AOSP kaynağına göre). Öneri: `adb reverse` yolu kalsın; USB tethering konusu kesin olarak kapatılsın.

### Varsayımlar / test edilmeyenler

- Yardımcı Kotlin yerine **Java** (tek dosya, `javac` + `d8`; Gradle/kotlinc olmadan `app_process` dex'i en kısa yol). Saf mantık (`Stats`, `errorName`) `StatsTest` ile host JVM'de sınanıyor (`build.sh`); `scripts/check.sh` bu dizini derlemiyor (Gradle/SwiftPM projesi değil).
- Kablo çıkar/tak ve tether üzerinden RTT/aktarım ölçülemedi (yukarıda).

### Tablette/Mac'te kontrol

- Orkestratör: MateBridge USB oturumu kendiliğinden geri geldi mi bak; gelmediyse kabloyu çıkar/tak (USB işlevi zaten `hisuite,mtp,mass_storage,adb`).
- Başka cihaz testi gerekmiyor.

## Open questions

- `probes/README.md` tablosuna `usb-tether-probe/` satırı eklenmeli (kartın `files:` listesinde değil, dokunulmadı). NOTES kaydı orkestratörde.
