# Sanal HID klavye/fare: GameController oyunları için araştırma (2026-10-06)

**İstek:** RE4 (Mac yerel) oyun içi menülerini `GameController` (`GCKeyboard`/`GCMouse`) üzerinden okuyor ve MateBridge'in `CGEvent` enjeksiyonunu görmüyor (NOTES 2026-10-06 ~13:50 ve ~14:10) [repo]. Kullanıcı, gerçek bir dezavantajı yoksa tablet klavyesinin ve faresinin her yerde çalışmasını istiyor.

**Bu belge karar değildir.** Yeni bağımlılık, sistem uzantısı ve root yardımcı süreç demek; karar kaydı ve kullanıcı onayı gerekir. Hiçbir şey kurulmadı, Mac'te GUI açılmadı, host'a ve tablete dokunulmadı.

Kanıt etiketleri: **[kaynak]** web kaynağı (sonda listelenir), **[repo]** depodaki dosya/satır, **[doğrulanmadı]** çıkarım, prob ya da ölçüm gerekiyor.

**Önemli geçmiş:** 2026-10-01'de kilit ekranı sorunu için "sanal HID sürücüsü + root yardımcı (Karabiner VirtualHIDDevice)" kullanıcıya önerildi ve **riskli bulunup reddedildi** (NOTES 2026-10-01 ~14:10) [repo]. Kilit ekranı sorunu sonradan CGEvent ile çözüldü. Bu öneri aynı bileşeni yeniden gündeme getiriyor; kullanıcıya bunu açıkça belirterek yeniden sorulmalı.

---

## 0. Kısa sonuç

- Bugün kişisel kullanım için **pratik tek yol: Karabiner-DriverKit-VirtualHIDDevice** (pqrs.org). Public domain, aktif bakımda, macOS 27 resmen destekleniyor. Bedeli şunlar: bir **sürücü uzantısı** (DriverKit, kullanıcı onaylar), sürekli çalışan bir **root daemon** (pqrs) ve bizim yazacağımız **root bir yardımcı süreç**. İstemciler yalnız root ile konuşabiliyor.
- Apple'ın önerdiği temiz yol **CoreHID `HIDVirtualDevice`** (root yok, sürücü yok). Ama `com.apple.developer.hid.virtual.device` **kısıtlı bir yetki**: ücretli Developer Program ve Apple onayı gerekiyor, geliştirme varyantı yok, başvurular aylarca bekliyor. Şu an kullanılamaz.
- Kendi DriverKit sürücümüzü yazmak Karabiner'le aynı mimari; çok daha fazla iş ve teknik bir kazancı yok.
- **Belirsiz olan asıl nokta:** GameController'ın `GCKeyboard`/`GCMouse` olarak sanal aygıtları görüp görmediği kaynaklarda doğrudan kanıtlanmamış. Apple DTS'e göre mimari olarak gerçek aygıtla aynılar, ama GameController'ın eşleştirmesi belgelenmemiş [kaynak]. Bu yüzden **ürün işinden önce bir go/no-go probu** gerekiyor (§6).
- Öneri: probu yapın. RE4 menüsü sanal aygıtla çalışırsa sanal HID'yi **yalnız Oyun modunda** ve yalnız klavye ile fare için açın. Kalem, dokunmatik ve trackpad hareketleri bugünkü CGEvent yolunda kalsın.

---

## 1. Sanal HID aygıtı sunmanın yolları

### 1(a) Karabiner-DriverKit-VirtualHIDDevice (pqrs.org)

**Ne yapıyor:** DriverKit ile sanal bir klavye (`VirtualHIDKeyboard`) ve sanal bir işaretçi (`VirtualHIDPointing`) oluşturuyor. macOS bunları fiziksel donanım gibi tanıyor [kaynak: README].

**Lisans:** Unlicense, yani public domain [kaynak: LICENSE.md]. Lisans açısından sorun yok.

**Bakım durumu:** Aktif. v8.0.0 (2026-07-03) ile v8.6.0 (2026-09-26) arasında sık sürüm çıkmış; v8.6.0 Xcode 27 için DriverKit 22.0 hedefliyor. `version.json`: `package_version 8.6.0`, `driver_version 1.8.0`, `client_protocol_version 7` [kaynak]. v8.0.0'da istemci protokolü 6'dan 7'ye çıktı; bu **kırıcı bir değişiklikti** [kaynak: releases]. Karabiner-Elements'in son sürümü 16.3.0 (2026-09-06) [kaynak].

**macOS desteği:** README'ye göre "macOS 27 Golden Gate (Apple Silicon), macOS 26 Tahoe, 15, 14, 13" [kaynak]. Mac mini macOS 27.0.1 kullanıyor (`sw_vers`) [repo/yerel]. Bu Mac'te şu an hiç sistem uzantısı yok (`systemextensionsctl list` → 0) [yerel, salt okuma].

**Kurulum akışı** [kaynak: README]:
1. pqrs'nin `.pkg` paketi açılır (yönetici parolası istenir).
2. `/Applications/.Karabiner-VirtualHIDDevice-Manager.app/.../Karabiner-VirtualHIDDevice-Manager activate` çalıştırılır.
3. macOS sürücü uzantısı onayı ister (Sistem Ayarları → Genel → Giriş Öğeleri ve Uzantılar). Gerekirse yeniden başlatılır.
4. `Karabiner-VirtualHIDDevice-Daemon` root olarak çalışır. Paket bir LaunchDaemon plist'i içeriyor (`org.pqrs.service.daemon.Karabiner-VirtualHIDDevice-Daemon`, `KeepAlive true`, `ProcessType Interactive`) [kaynak: repo `files/LaunchDaemons`]. Repodaki `SMAppServiceExample`, bu daemon'u `SMAppService.daemon(plistName:)` ile kaydetmeyi gösteriyor [kaynak].
5. İstemci program çalıştırılır.

Kaldırma: deactivate betiği, dosyaları silme betiği (sudo) ve daemon'u durdurma [kaynak].

**Uzantının yetkileri:** `driverkit`, `driverkit.family.hid.device`, `driverkit.family.hid.eventservice`, `driverkit.transport.hid`, App Sandbox ve pqrs Team ID'si (G43BCU2T37) [kaynak: `src/DriverKit/entitlements.plist`]. Uzantı pqrs tarafından imzalanıp dağıtılıyor; **bizim Apple yetkisi almamız gerekmiyor**. Bizim yazacağımız istemci sıradan bir root süreci.

**İstemci API'si** [kaynak: `client.hpp`, `parameters.hpp`, `constants.hpp`, örnek istemci]:
- Header-only **C++23** kütüphanesi (`pqrs::karabiner::driverkit::virtual_hid_device_service::client`). Asio, nod, pqrs::dispatcher gibi bağımlılıkları repoda vendor olarak duruyor.
- Daemon'la iletişim Unix soketi üzerinden: `/Library/Application Support/org.pqrs/tmp/rootonly/karabiner_virtual_hid_device_service.sock`. Mesaj üst sınırı 1024 bayt. Heartbeat zaman aşımı 30 s, yeniden bağlanma 1 s.
- Metotlar:
  - bağlantı: `async_start` / `async_stop`;
  - klavye: `async_virtual_hid_keyboard_initialize(parameters)` / `_terminate` / `_reset`;
  - işaretçi: `async_virtual_hid_pointing_initialize` / `_terminate` / `_reset`;
  - rapor gönderme: `async_post_report(keyboard_input | consumer_input | apple_vendor_keyboard_input | apple_vendor_top_case_input | generic_desktop_input | pointing_input)`.
- Sinyaller: `connected`, `closed`, `driver_activated`, `driver_connected`, `driver_version_mismatched`, `virtual_hid_keyboard_ready`, `virtual_hid_pointing_ready`.

**Root zorunluluğu:** Evet. "The software incorporating the client library must be run with root privileges" [kaynak: README]. Soket `rootonly` dizininde. Karabiner'in güvenlik belgesine göre daemon "only receives data from processes running with root privileges", böylece sıradan uygulamalar sanal aygıta olay gönderemiyor [kaynak: security]. **MateBridge.app (kullanıcı süreci) doğrudan istemci olamaz.** Bir root yardımcı süreç şart.

**Klavye** [kaynak: `VirtualHIDKeyboard.cpp`, `parameters.hpp`]:
- Rapor 1: 8 değiştirici bit ve en fazla 32 eşzamanlı tuş (16 bit usage). Ayrıca consumer, Apple vendor ve generic desktop raporları var.
- Parametreler: `vendor_id` (varsayılan 0x16c0), `product_id` (0x27db), `country_code` (varsayılan `not_supported`).
- **Klavye türü (ANSI/ISO/JIS):** tanımlayıcıda yok. macOS bunu ülke kodundan ya da Klavye Kurulum Yardımcısı'ndan alıyor. Karabiner-Elements'te ISO için ülke kodu > 0 seçiliyor, ve "bu sayıyı artırmak macOS Klavye Kurulum Yardımcısı'nı tetikler" [kaynak: KE issue #2802 ve arama özeti]. KE 14.12.0 dinamik ANSI/ISO/JIS değişimini düzeltti. KE 15.1.0 fn tuşu için sanal klavyenin VID/PID'ini gerçek bir Apple harici klavyesininkiyle aynı yaptı [kaynak: KE release notes].
- **MateBridge için sonuç:** Bugün CGEvent'e `keyboardEventKeyboardType = 41` (ISO) yazılıyor (karar 0008) [repo: `CGEventPoster.swift`]. HID yolunda bu alan yok; tür aygıt düzeyinde belirleniyor. İlk bağlantıda Mac'te **Klavye Kurulum Yardımcısı penceresi açılabilir**; tablet Mac'in tek ekranı olduğu için kullanıcı bunu tablette görür ve bir kez kapatır. ISO'daki `§`/`` ` `` takası HID usage 0x64/0x35 ile yeniden doğrulanmalı (KE #3155, #4070'te bu takas sorunları raporlanmış) [doğrulanmadı].

**İşaretçi** [kaynak: `VirtualHIDPointing.cpp`]:
- 32 düğme.
- **Yalnız göreli** X/Y: her biri 8 bit, −127..127.
- Dikey tekerlek 8 bit ve yatay tekerlek (AC Pan) 8 bit, ikisi de −127..127.
- Mutlak konum yok, piksel hassasiyetinde sürekli kaydırma yok, faz yok, jest yok.
- Sonuçlar:
  - büyük deltalar ±127'lik parçalara bölünmeli;
  - macOS işaretçi ivmesini HID hareketine uygular. Oyunlar `GCMouse` ile ham deltayı alır, ama masaüstündeki imleç hissi değişir [doğrulanmadı];
  - trackpad'in yumuşak kaydırması HID'de "çentik" olur.

**Karabiner-Elements ile birlikte çalışma** [kaynak + çıkarım]:
- Kanata ile KE arasındaki bilinen çakışma, fiziksel klavyeyi **özel erişimle tutmaktan** (seize) kaynaklanıyor ("exclusive access and device already open"). MateBridge hiçbir aygıtı tutmuyor, yalnız rapor gönderiyor.
- Daemon her istemci (peer) için ayrı bir `client_entry` ve ayrı bir sanal klavye/işaretçi tutuyor [kaynak: `virtual_hid_device_service_clients_manager.hpp`]. Bu nedenle KE ile yan yana çalışmak mümkün görünüyor [doğrulanmadı]. Ayrıca açık bir "Could this support multiple clients?" issue'su var (#46).
- **Gerçek risk sürüm uyumu.** Makinede sürücünün tek kopyası olur. Kullanıcı ileride KE kurarsa ya da günceller ve paketlediği sürücü sürümü farklıysa, istemci protokolü uyuşmazlığında (`driver_version_mismatched`, `connect_failed`) bizim yardımcı süreç bozulur. Kanata topluluğu sürücü sürümünü sabitlemeyi öneriyor ("v6.2.0'dan yenisiyle connect_failed") [kaynak]. → Sürüm sabitlenmeli, uyuşmazlık loglanıp kullanıcıya gösterilmeli.

**Bilinen sorunlar** [kaynak]:
- macOS 26.4 beta'da dahili klavye olayları DriverKit sanal HID katmanına ulaşmadı. Bu, yakalama yönünü etkiledi, gönderme yönünü değil; 2026-04'te düzeldi.
- Açık issue'lar: "Keyboard disconnects randomly on macOS 15.5" (#42), "Mouse cursor stuck" (#39, belirli bir Logitech fareyle). İşletim sistemi güncellemeleri bu katmanı zaman zaman kırabiliyor.

### 1(b) CoreHID `HIDVirtualDevice` / `IOHIDUserDeviceCreate`: `com.apple.developer.hid.virtual.device`

- `HIDVirtualDevice` macOS 15'ten beri var. Swift `actor`; `HIDVirtualDevice(properties:)`, `activate(delegate:)` ve `dispatchInputReport(data:timestamp:)` [kaynak: Apple docs]. Yetki macOS 10.15'ten beri (`IOHIDUserDeviceCreate` için de aynısı).
- **Kısıtlı yetki.** Apple DTS (Kevin Elliott): "Both DriverKit and Core HID require restricted entitlements … Virtual Core HID does not currently have a development variant … using these entitlements currently requires joining the paid program." [kaynak: forum 820708]. Kısıtlamanın gerekçesi: "virtual HID devices can be used to create a variety of attacks against the system".
- Başvuru, Certificates, Identifiers & Profiles → Capability Requests → "HID Virtual Device" üzerinden yapılıyor. Bir geliştiricinin 2026-06-30 tarihli başvurusu 2,5 aydır "Submitted"; DTS'in yanıtı: "some requests are taking a while" [kaynak: forum 845599].
- `HIDVirtualDevice` oluşturmak **Erişilebilirlik** istemini tetikliyor. MateBridge'in bu izni zaten var. App Store'da bu yüzden reddedilen bir uygulama var; bizim için önemsiz [kaynak: forum 820676].
- Yetkisiz bir ikilide oluşturma başarısız oluyor [kaynak: crossinput #153]. Tek yetkisiz yol SIP ve AMFI'yi kapatmak; DTS de önermiyor [kaynak: 820708]. Bu bizim için kabul edilemez.
- **MateBridge'in durumu:** imza kimliği "Apple Development: …" [repo: `scripts/bundle-host.sh`; yerel `security find-identity`]. Hesabın ücretli mi Personal Team mi olduğu bilinmiyor [doğrulanmadı]. Ücretli olsa da Apple onayı gerekiyor ve geliştirme varyantı yok. **Bugün kullanılamaz.**
- Avantajı büyük: root yok, üçüncü taraf sürücü yok, sistem uzantısı yok. DTS'e göre "architecturally they both work in EXACTLY the same way. CoreHID is just using a kernel extension we wrote instead of the DEXT you'd have to write" [kaynak: 845599]. Apple geliştirme varyantı eklerse (r.173531752) ya da başvuru onaylanırsa tercih edilecek yol bu olur.

### 1(c) Kendi DriverKit HID sürücümüz

- Gereken yetkiler: `com.apple.developer.driverkit` ve `driverkit.family.hid.device` / `.eventservice` / `driverkit.transport.hid` (Karabiner'in kullandıkları) [kaynak].
- `com.apple.developer.driverkit.family.hid.virtual.device` **geçersiz ("defunct")**. Hiçbir işe yaramıyor, belgelerden kaldırılacak (r.184046926) [kaynak: forum 840311].
- DriverKit yetkilerinin "Development Only" varyantları portaldan onaysız ekleniyor, ama bu da ücretli üyelik istiyor [kaynak: 820708]. Geliştirme imzalı bir uzantının bu Mac'te SIP açıkken yüklenip yüklenmeyeceği [doğrulanmadı].
- DTS: "I also have NO idea why anyone would choose to implement a virtual device using a DEXT … a lot of extra work with no meaningful benefit" [kaynak: 840311].
- Karabiner'e göre kazancı yok: aynı mimari, aynı onay akışı, üstelik bakımı bize kalır. **Elenir.**

### 1(d) Diğer yollar

- **`GCVirtualController`:** yalnız iOS, iPadOS ve Mac Catalyst (15.0+) [kaynak: Apple docs JSON]. Uygulamanın kendi içindeki ekran üstü denetleyici; başka bir sürece (RE4'e) görünmez. **İşe yaramaz.**
- **Sanal gamepad (RE4 menüsünü gamepad'le gezmek):** aynı kısıtlı yetkiyi istiyor. GameController gamepad'leri belirli donanım ayrıntılarına göre eşliyor. Sunshine'ın `IOHIDUserDeviceCreate` ile yaptığı sanal gamepad'i "doesn't work on apps which rely on … GameController.framework" [kaynak: Sunshine PR #5171]. **Elenir.**
- **Tablet Mac'e Bluetooth HID aygıtı olarak görünür** (Android `BluetoothHidDevice`, API 28+):
  - Mac'te hiçbir şey kurulmaz. Mac'e göre bu gerçek bir BT klavye/fare, dolayısıyla GameController onu büyük olasılıkla görür.
  - Bilinmeyenler [doğrulanmadı]: HarmonyOS 4.3'ün bu profili sunup sunmadığı; tabletin kendi BT fare/klavyesine host olurken aynı anda HID aygıtı olabilip olamadığı.
  - Bilinen kısıtlar: aynı anda yalnız bir HID uygulaması kaydedilebilir [kaynak].
  - Dezavantajlar: BT eşleştirmesi, BT gecikmesi (bağlantı aralığı), 2,4 GHz Wi-Fi ile radyo paylaşımı. Ayrıca girdi MateBridge oturumundan ayrı bir kanaldan gider; release-all kuralı BT bağlantısının kopmasına kalır.
  - İlginç bir **sıfır kurulumlu yedek**, ama gerçekçi değil. Önce tablet tarafında ucuz bir prob gerekir (profil var mı?).
- **USB gadget (tablet USB HID klavye olarak):** Android'de root/configfs gerekir. **Elenir.**
- **SIP/AMFI'yi kapatıp yetkisiz CoreHID:** sistem güvenliğini düşürür. **Elenir.**
- **Bugünkü durum:** RE4 menüsünde Mac'e doğrudan bağlı fareyi kullanmak (NOTES ~14:10) [repo].

---

## 2. GameController sanal aygıtları kabul ediyor mu?

**Doğrudan kanıt bulunamadı.** Dolaylı kanıtlar:

- **Lehte:**
  - DTS, CoreHID ya da DEXT ile yapılan sanal aygıtların "true HID device that can replicate the same capabilities a physical controller does" olduğunu ve iki yolun mimari olarak aynı olduğunu söylüyor [kaynak: 820708, 845599].
  - Karabiner README: aygıtlar "recognized by macOS in the same way as physical hardware".
  - `GCKeyboard.coalesced` "the keyboard currently connected" anlamına geliyor, yani bağlı klavyelerin birleşimi. `GCMouse` "a physical mouse connected" olarak tanımlı [kaynak: Apple docs]. Klavye ve fare için gamepad'deki gibi belirli VID/PID eşlemesi olduğuna dair bir işaret yok.
  - Karabiner-Elements fiziksel klavyeyi tutup bütün girdiyi sanal klavyeden veriyor. GCKeyboard sanal klavyeyi görmeseydi, KE kullanıcıları GCKeyboard kullanan her oyunda klavyesiz kalırdı. KE issue'larında böyle bir şikâyet bulamadım. Bu zayıf bir kanıt: yokluğun kanıtı [doğrulanmadı].
- **Aleyhte ya da belirsiz:**
  - DTS'in gamepad için çekincesi: "GameController.framework matches against specific (undocumented) hardware details … it's possible there's some detail I've overlooked" [kaynak: 845599].
  - Sunshine'ın sanal gamepad'i GameController'da görünmüyor; ama gamepad eşleme kuralı klavye ve fareden farklı [kaynak].
- **İlgili örüntü:** SDL3 macOS'ta herhangi bir `GCMouse` bağlıyken NSEvent fare düğmelerini **tamamen atıyor**. CGEvent ile enjekte edilen tıklamalar (VNC, uzaktan erişim) bu yüzden kayboluyor [kaynak: SDL #16241, açık]. Yani GCMouse kullanan oyunlarda CGEvent enjeksiyonunun ulaşmaması genel bir sorun ve tek çözümü HID düzeyinde bir aygıt.

**Sonuç:** Muhtemelen çalışır [doğrulanmadı]. Ürün işinden önce §6'daki probla **kesinleştirilmeli**.

---

## 3. Güvenlik, entegrasyon, efor, mod ve takılma güvenliği

### 3.1 Güvenlik etkileri

- **Sürücü uzantısı (dext):** çekirdekte değil, DriverKit kum havuzunda kullanıcı alanında çalışıyor (yetkilerde App Sandbox var) [kaynak]. pqrs imzalı ve Karabiner-Elements ile yaygın kullanılıyor. Yine de **tedarik zinciri güveni** üçüncü bir tarafa açılıyor: güncellemeler pkg ile ve yönetici parolasıyla geliyor.
- **pqrs root daemon:** sürekli çalışıyor (`KeepAlive`). Saldırı yüzeyi, yalnız root'a açık bir soket.
- **Bizim root yardımcı sürecimiz: asıl yeni risk.** Bugün CGEvent göndermek **Erişilebilirlik izni** (TCC) gerektiriyor [repo: `CGEventPoster.swift` belgesi]. Sanal HID yolunda bu kapının yerini "root" alıyor. Yardımcı süreç her yerel süreçten komut kabul ederse, **TCC'yi atlayan bir tuş vuruşu enjektörüne** dönüşür. Zorunlu önlemler:
  - IPC yalnız MateBridge.app'in imzasından: XPC dinleyicisi ve `xpc_connection_set_peer_code_signing_requirement` ya da `xpc_listener_set_peer_code_signing_requirement` (macOS 12+, SDK'da mevcut) [yerel SDK başlığı]. Gereksinim: Team ID + bundle id.
  - Yardımcı süreç yalnız dar bir komut kümesini kabul eder: "tuş usage aşağı/yukarı", "göreli hareket", "düğme maskesi", "tekerlek", "hepsini bırak". Komut sayısı ve oranı sınırlanır. Dosya, kabuk ya da başka bir yetenek yok.
  - Sanal aygıtlar **yalnız gerektiğinde var olur:** Oyun modunda `initialize`, çıkışta `terminate`. Böylece klavye kullanılmadığı sürece sistemde fazladan bir klavye durmaz.
  - Loglama: karakter yok, usage değerleri yalnız `debug` seviyesinde (AGENTS.md gizlilik kuralı) [repo].
- **TCC ve kilit ekranı:** HID düzeyindeki girdi gerçek klavye gibidir. Secure Event Input, kilit ekranı ve parola alanları dahil her yerde çalışır. Bu bir yetenek artışı, ama zaten CGEvent ile kilit açılabiliyor (NOTES 2026-10-01 ~14:45 düzeltmesi) [repo].
- **İşletim sistemi güncellemeleri:** macOS güncellemeleri DriverKit HID katmanını kırabiliyor (26.4 beta örneği) [kaynak]. Kırıldığında sessizce CGEvent'e geri dönmek gerekir (§3.4).

### 3.2 En küçük entegrasyon (öneri taslağı)

```
Tablet ── KEY / POINTER_REL / düğme / SCROLL ──► Host InputPipeline (değişmez, MateBridgeCore)
                                                     │ [MacEvent]
                                         RoutingPoster (yeni, MacEventPoster)
                                    ┌────────────────┴─────────────────┐
                     kalem, dokunma, magnify,               (HID modu açıkken) key, mouse
                     mutlak işaretçi, trackpad kaydırma     düğme/göreli hareket, tekerlek
                                    ▼                                  ▼
                        CGEventPoster (bugünkü)            HIDEventPoster ──XPC──► matebridge-hid-helper (root)
                                                                                    │ pqrs client (C++23)
                                                                                    ▼ rootonly unix soketi
                                                                      Karabiner-VirtualHIDDevice-Daemon (root, pqrs)
                                                                                    ▼
                                                                      DriverKit VirtualHIDKeyboard / Pointing
```

- **Host (Swift):**
  - `MacEventPoster` arayüzünün [repo: `CGEventPoster.swift:7`] ikinci uygulaması `HIDEventPoster` ve ikisini seçen `RoutingPoster`. `InputPipeline` ve durum makinesi değişmez. Başarısız gönderimler bugünkü `OwedRelease` mantığıyla geri döner.
  - Saf, birim testli bir parça `MateBridgeCore`'a girer: macOS virtual keycode → HID usage tablosu, ≤32 tuşluk basılı küme + değiştirici baytı, ±127'ye bölme, düğme maskesi. Bu fixture testlerine uygun.
- **Yardımcı süreç (C++):**
  - pqrs'nin header-only istemcisiyle küçük bir program; repodaki `examples/virtual-hid-device-service-client` temel alınır.
  - XPC Mach servisi olarak bir **LaunchDaemon** şeklinde çalışır. İki kurulum yolu var:
    - **SMAppService.daemon** (plist `.app/Contents/Library/LaunchDaemons/` altında, kullanıcı Giriş Öğeleri'nde onaylar). Apple Development imzası ve notarize edilmemiş bir uygulamayla çalışıp çalışmadığı [doğrulanmadı]. Forumlarda "Operation not permitted" ve `requiresApproval` tuzakları raporlanmış [kaynak].
    - **Yedek:** kanata gibi `sudo` ile `/Library/LaunchDaemons`'a kurulan bir plist (`root:wheel`) [kaynak: kanata #1537]. Bir `scripts/install-hid-helper.sh` betiği yeter.
  - Swift C++ interop ile C++23, asio ve pqrs bağımlılıklarını derlemek riskli. Yardımcı ayrı bir C++ hedefi olmalı (repodaki Makefile ve xcodegen düzeni).
- **Yeni bağımlılıklar:**
  - pqrs sürücü paketi (kullanıcı kurar; sürüm sabitlenir);
  - pqrs istemci kütüphanesi ve vendor bağımlılıkları (derleme zamanı).
  - AGENTS.md: "Do not add dependencies without a decision record" → **karar kaydı şart** [repo].
- **Hangi modda açılacağını host nereden bilir:** mod bir istemci kavramı; host bilmiyor (karar 0030 §6) [repo]. Seçenekler:
  - (i) host'ta yerel bir ayar ("Oyun girişi: sanal HID");
  - (ii) 0029 oyun ekranı etkinken HID açık (host bunu `STREAM_PREFS display_*` ile zaten biliyor) [repo: `GameDisplayPolicy.swift`];
  - (iii) protokolde yeni bir bayrak. Bu orkestratörün işi; fixture ve Codex `--high` incelemesi gerekir.

  (ii) protokol değiştirmediği için en ucuzu.

### 3.3 Efor tahmini (ajan-günü, kaba) [doğrulanmadı]

| Adım | Efor |
|---|---|
| Go/no-go probu (§6): kullanıcı pkg'yi kurar ve onaylar; örnek istemciyle RE4 menüsü; GameController bağlantı listesi | 0,5–1 |
| Karar kaydı (bağımlılık, güvenlik modeli, mod kuralı, takılma kuralları) | 0,5 |
| Root yardımcı süreç: C++, XPC, imza gereksinimi, heartbeat/watchdog, yeniden bağlanma, sürüm uyuşmazlığı | 2–3 |
| Host: `HIDEventPoster` + `RoutingPoster`, keycode→usage tablosu, rapor durumu, testler | 2–3 |
| Kurulum/kaldırma betikleri, durum göstergesi/log, `check.sh` entegrasyonu | 1 |
| Cihaz testleri (RE4, ISO tuşları, Klavye Kurulum Yardımcısı, takılma: yardımcıyı/daemon'u `kill -9`) + Codex `--high` | 1 |
| **Toplam** | **~7–10** |

Kartlara bölünür: prob, karar, yardımcı süreç, host yönlendirme, cihaz testi.

### 3.4 Oyun modunda mı, her zaman mı?

**Öneri: yalnız Oyun modunda, yalnız klavye ve fare için.** Gerekçe: Günlük ve Çizim modlarında CGEvent yolu HID yolunun veremediği şeyleri veriyor:

- sanal ekranda **mutlak** işaretçi konumu (HID işaretçisi yalnız göreli);
- **piksel hassasiyetinde ve fazlı kaydırma** (HID'de tekerlek çentiği);
- magnify jesti;
- olay başına açık `flags` (Mac'in kendi klavye durumu sızmıyor);
- olay başına ISO `kbdtype`;
- host'un kontrol ettiği **tuş tekrarı** ve takılmada tekrarı duraklatma (T-163).

HID'de bunların bir kısmı kayboluyor ya da işletim sistemine geçiyor. Kalem (basınç ve eğim, tablet proximity) **her zaman CGEvent'te** kalır: Karabiner'in işaretçisi digitizer değil, bu yolda kalem desteği yok.

Oyun modunda bile:
- **Yönlendirme tuş başına sabitlenir:** bir tuş HID'den indiyse HID'den kalkar. Bugünkü "DOWN'da kaydedilen keycode'u bırak" kuralının (PROTOCOL §KEY) yol versiyonu [repo]. HID modu açılıp kapanırken önce release-all yapılır.
- **Fare düğmeleri ve hareket aynı yoldan gider.** HID göreli hareketi ivmeli imleci taşır; CGEvent tıklaması ise host'un hesapladığı mutlak konuma gider. İkisi karışırsa konumlar ayrışır. Ayrıca SDL tipi oyunlar GCMouse varken CGEvent tıklamalarını atıyor [kaynak: SDL #16241].
- Trackpad kaydırması CGEvent'te kalabilir; tablete bağlı farenin tekerleği HID'ye gider. Bu ayrıntı kart düzeyinde karara bağlanır.
- **Geri dönüş:** yardımcı süreç ya da sürücü yoksa veya sürüm uyuşmazsa sessizce CGEvent kullanılır ve bir kez `warning` loglanır.

### 3.5 Tuş tekrarı ve takılma güvenliği (AGENTS.md: girdi asla takılı kalmaz)

- **Tekrar:** HID klavyesi tekrar göndermez; tuş basılı tutulduğu sürece **macOS tekrarı kendisi üretir** [doğrulanmadı; gerçek klavye davranışı]. Sonuçlar:
  - host, HID'ye giden tuşlar için kendi tekrar üretecini **kapatmalı**. Yoksa çift tekrar olur. `isRepeat` olayları da HID'ye gönderilmemeli;
  - T-163'teki "takılmada tekrarı duraklat ama UP üretme" davranışı HID'de **uygulanamaz**. Bağlantı takılırken basılı bir tuş (ör. Backspace) Mac'te tekrarlanmaya devam eder.
  - Öneri: HID yolunda kontrol sessizliği 600 ms'yi aşarsa basılı tuşlar **erken bırakılır**. Bırakmak her zaman güvenli; sonradan gelen UP yok sayılır. Bu, 0025 eski girdi politikasına bir ek olur ve orkestratörün kararıdır [repo].
- **Release-all:** HID yolunda boş klavye raporu (tuş yok, değiştirici yok) ve `buttons=0` işaretçi raporu gönderilir, ardından `async_virtual_hid_keyboard_reset` / `_pointing_reset`. CGEvent tarafı bugünkü gibi kalır. Tetikleyiciler değişmez (PROTOCOL §7: kopma, arka plan, BYE, RELEASE_ALL, watchdog).
- **Katmanlı emniyet:**
  1. **Host düşerse ya da donarsa:** yardımcı süreç XPC bağlantısının koptuğunu görür. Ayrıca host'tan ~1 s heartbeat gelmezse kendi kendine release-all + reset yapar.
  2. **Yardımcı süreç düşerse:** pqrs daemon peer'ı siler (`erase_client`). Sanal klavye/işaretçi nesneleri serbest kalır ve aygıt kaybolur [kaynak: `clients_manager.hpp`, `VirtualHIDDeviceUserClient::free`]. **Aygıt kaybolunca macOS'un basılı tuşları bırakıp bırakmadığı** [doğrulanmadı] → probda `kill -9` testi yapılmalı.
  3. **Daemon düşerse:** dext'in user client'ı kapanır; aynı durum (2). launchd daemon'u yeniden başlatır. Yardımcı süreç yeniden bağlanınca önce `reset` yapar.
  4. **Gönderim başarısızlığı:** `async_post_report` "gönder ve unut" çalışıyor. Bırakma olayları için yardımcı süreç XPC yanıtında başarı bildirmeli; host başarısızlığı `OwedRelease` ile yeniden dener [repo].
- **Caps Lock:** HID'den gönderilmez. Bugünkü `IOHIDSetModifierLockState` yolu kalır [repo: PROTOCOL §KEY Caps]. Apple VID'li bir klavyede Caps Lock gecikmesi de böylece devreye girmez [doğrulanmadı].

---

## 4. Gecikme

- **CGEvent:** `CGEventPost(.cghidEventTap)` süreç içinden doğrudan WindowServer'ın HID katmanına gidiyor. Maliyet mikrosaniyeler düzeyinde [doğrulanmadı]. Bugünkü `input_age` ve `ev=latency` ölçümleri bu yolu içeriyor [repo].
- **Sanal HID:** host → XPC (onlarca µs) → yardımcı süreç → Unix soketi → pqrs daemon (dispatcher iş parçacığı) → `IOConnectCall` → dext → IOHIDFamily → HID olay sistemi → WindowServer/GameController.
  - Beklenti: **toplam ≪ 1 ms ile birkaç ms** arası [doğrulanmadı].
  - Bir kaynak sistem uzantısı için "3–5 ms" diyor, ama zayıf (yapay zekâ özetli bir wiki) [kaynak: deepwiki].
  - Kanata topluluğu bu yolu "en düşük gecikmeli ve en güvenilir" diye anlatıyor [kaynak].
  - v7.1.0'da başlangıç gecikmesi azaltılmış [kaynak].
- **Bağlam:** görüntü yolu ~40–55 ms, USB RTT ~2 ms [repo: research 2026-10-04]. HID yolunun eklediği gecikme hissedilmez sınırda kalmalı.
- **Ölçüm önerisi (probda):** yardımcı sürecin gönderim zamanı ile dinleyen bir `CGEventTap`'te görülen olay zaman damgası karşılaştırılır. Aynısı CGEvent yolu için de yapılır. 1000 olayın p50/p95 değerleri alınır.

---

## 5. Öneri ve kullanıcı için dezavantajlar

**Öneri:**
1. **Önce go/no-go probu** (§6, yarım gün; kullanıcı bir kez kurulum ve onay yapar). Sonra ikisinden biri:
2. a) RE4 menüsü sanal klavye/fareyle **çalışıyorsa** ve takılma testleri geçiyorsa: karar kaydı ile **yalnız Oyun modunda** sanal HID (klavye + fare), kalem ve diğer her şey CGEvent'te.
   b) **Çalışmıyorsa:** dur, paketi kaldır. Tabletin BT HID profilini ayrı bir ucuz probla değerlendir ya da bugünkü yolda kal (menüde Mac faresi).
3. Paralelde, kullanıcının ücretli bir Apple Developer hesabı varsa CoreHID yetkisi için başvurulabilir. Onaylanırsa root ve sürücü olmadan aynı işi yapan temiz yola geçilir.

**Kullanıcı için dezavantajlar (açık liste):**
- Mac'e **üçüncü taraf bir sürücü uzantısı** kurulur (pqrs). Kurulumda yönetici parolası, Sistem Ayarları'nda uzantı onayı ve belki yeniden başlatma gerekir. Sonra da arka plan öğesi onayı.
- **İki root süreç** sürekli çalışır: pqrs daemon ve MateBridge yardımcı süreci. Saldırı yüzeyi büyür; root yardımcı süreç yanlış yazılırsa TCC'yi atlayan bir girdi kapısı olur. (Kullanıcı 2026-10-01'de tam olarak bu riski gerekçe gösterip reddetmişti.)
- **Bağımlılık ve bakım:** pqrs sürüm güncellemeleri ve istemci protokolü değişiklikleri (v8'de kırıcı değişiklik oldu), macOS güncellemelerinin bu katmanı kırma ihtimali, Karabiner-Elements kurulursa sürüm çakışması.
- Mac'te **yeni bir klavye ve fare görünür** (Sistem Ayarları'nda, `GCMouse` listesinde). İlk bağlantıda **Klavye Kurulum Yardımcısı penceresi** açılabilir. Klavye türü (ISO) aygıt düzeyinde ayarlanır; `§`/`` ` `` tuşları yeniden doğrulanmalı.
- HID modunda fare **macOS ivmesiyle** hareket eder (oyunda ham delta, masaüstünde his değişir). Tekerlek çentikli olur. Mutlak konum ve jest yoktur. Bu yüzden yalnız Oyun modunda kullanılır.
- Tuş tekrarını macOS üretir. Wi-Fi takılmasında basılı tuş tekrarlanmaya devam edebilir; erken bırakma kuralıyla sınırlanır.
- Kaldırmak için ayrı adımlar gerekir (deactivate, dosya silme, daemon durdurma).
- Kazanç dar olabilir: bugün yalnız RE4 menüsü (ve GCKeyboard/GCMouse kullanan başka oyunlar) için gerekiyor; oynanış zaten çalışıyor.

---

## 6. Go/no-go probu (öneri; kullanıcı onayıyla, tek seferde, paralel ajan yok)

1. Kullanıcı pqrs v8.6.0 pkg'sini kurar, `activate` eder, uzantıyı onaylar ve daemon'u başlatır.
2. Bir **CLI probu** (pencere açmaz) `GCKeyboard.coalesced` ve `GCMouse.mice()` listesini ve `GCKeyboardDidConnect` / `GCMouseDidConnect` bildirimlerini, sanal aygıt başlatılmadan önce ve sonra yazdırır (`vendorName`, `productCategory`). Bu, GameController'ın aygıtı görüp görmediğini **RE4'süz** gösterir [doğrulanmadı: bildirimler arka planda gelir mi].
3. Örnek istemci (`sudo`), RE4 menüsü öndeyken 5 s gecikmeyle ok tuşları, Enter, göreli fare hareketi ve sol tık gönderir. Kullanıcı menünün tepki verip vermediğini söyler.
4. **Takılma testi:** istemci bir tuşu basılı tutarken `kill -9` edilir. Mac'te tekrar durmalı ve tuş bırakılmalı. Aynısı daemon için yapılır.
5. Gecikme ölçümü (§4) ve ISO tuşlarının kontrolü.
6. Sonuç `docs/NOTES.md`'ye yazılır. "Hayır" çıkarsa paket kaldırılır.

---

## Kaynaklar

- pqrs-org/Karabiner-DriverKit-VirtualHIDDevice: [README](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice), [releases](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice/releases), [client.hpp](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice/blob/main/include/pqrs/karabiner/driverkit/virtual_hid_device_service/client.hpp), [constants.hpp](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice/blob/main/include/pqrs/karabiner/driverkit/virtual_hid_device_service/constants.hpp), [parameters.hpp](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice/blob/main/include/pqrs/karabiner/driverkit/virtual_hid_device_service/parameters.hpp), [VirtualHIDPointing.cpp](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice/blob/main/src/DriverKit/Karabiner-DriverKit-VirtualHIDDevice/org_pqrs_Karabiner_DriverKit_VirtualHIDPointing.cpp), [VirtualHIDKeyboard.cpp](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice/blob/main/src/DriverKit/Karabiner-DriverKit-VirtualHIDDevice/org_pqrs_Karabiner_DriverKit_VirtualHIDKeyboard.cpp), [DriverKit entitlements](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice/blob/main/src/DriverKit/entitlements.plist), [LaunchDaemon plist](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice/blob/main/files/LaunchDaemons/org.pqrs.service.daemon.Karabiner-VirtualHIDDevice-Daemon.plist), [SMAppServiceExample](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice/tree/main/examples/SMAppServiceExample), [clients_manager.hpp](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice/blob/main/src/Daemon/include/virtual_hid_device_service_clients_manager.hpp), [issue #46](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice/issues/46), [#42](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice/issues/42), [#39](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice/issues/39)
- Karabiner-Elements: [Security](https://karabiner-elements.pqrs.org/docs/help/advanced-topics/security/), [Release notes](https://karabiner-elements.pqrs.org/docs/releasenotes/), [#2802 ülke kodu](https://github.com/pqrs-org/Karabiner-Elements/issues/2802), [#3155](https://github.com/pqrs-org/Karabiner-Elements/issues/3155), [#4070](https://github.com/pqrs-org/Karabiner-Elements/issues/4070)
- Kanata: [Discussion #1537 (launchd, root, KE çakışması)](https://github.com/jtroo/kanata/discussions/1537), [#2088](https://github.com/jtroo/kanata/issues/2088)
- Apple: [com.apple.developer.hid.virtual.device](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.hid.virtual.device), [HIDVirtualDevice](https://developer.apple.com/documentation/corehid/hidvirtualdevice), [Creating virtual devices](https://developer.apple.com/documentation/corehid/creatingvirtualdevices), [GCVirtualController](https://developer.apple.com/documentation/gamecontroller/gcvirtualcontroller), [GCMouse](https://developer.apple.com/documentation/gamecontroller/gcmouse), [GCKeyboard.coalesced](https://developer.apple.com/documentation/gamecontroller/gckeyboard/coalesced)
- Apple Developer Forums: [820708 (kısıtlı yetkiler, ücretli program, CoreHID önerisi)](https://developer.apple.com/forums/thread/820708), [845599 (CoreHID ≈ DEXT, GameController çekincesi, bekleyen başvuru)](https://developer.apple.com/forums/thread/845599), [840311 (defunct DriverKit virtual entitlement)](https://developer.apple.com/forums/thread/840311), [820676 (HIDVirtualDevice Erişilebilirlik istemi)](https://developer.apple.com/forums/thread/820676), [737230 (yetki + sandbox)](https://developer.apple.com/forums/thread/737230), [817009 (26.4 beta DriverKit HID)](https://developer.apple.com/forums/thread/817009), [762551 (SMAppService "Operation not permitted")](https://developer.apple.com/forums/thread/762551)
- Diğer: [SDL #16241 (GCMouse varken CGEvent tıklamaları atılıyor)](https://github.com/libsdl-org/SDL/issues/16241), [Sunshine PR #5171 (IOHIDUserDevice gamepad, GameController'da görünmüyor)](https://github.com/LizardByte/Sunshine/pull/5171), [crossinput #153](https://github.com/luceat-lux-vestra/crossinput/issues/153), [Android BluetoothHidDevice](https://developer.android.com/reference/android/bluetooth/BluetoothHidDevice), [Kontroller](https://github.com/raghavk92/Kontroller), [deepwiki: Karabiner Virtual HID Device (zayıf kaynak)](https://deepwiki.com/pqrs-org/Karabiner-Elements/3.4-virtual-hid-device)
