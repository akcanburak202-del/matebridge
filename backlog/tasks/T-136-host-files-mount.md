---
id: T-136
title: Mac — FILES_INFO ile adb forward, WebDAV birimini bağla, menü "Tablet dosyalarını aç"
status: review
phase: 5
owner: mac-host-dev
depends_on: []
decisions: [0015]
files:
  - host-mac/Sources/
  - host-mac/Tests/
  - backlog/tasks/T-136-host-files-mount.md
---

## Amaç

Karar 0015: Mac'ten tabletteki dosyalara Finder ile erişim. Mac tarafı: `FILES_INFO` (PROTOCOL §4 0x09, fixture `files_info_ready`, `files_info_off`) alınca USB oturumunda `adb forward` kurmak ve kullanıcıya Finder'da açmak.

## Kabul kriterleri

- [x] Protokol: `FILES_INFO` çözme/kodlama, `FixtureTests`'e iki fixture.
- [x] READY + oturum USB: mevcut `UsbTunnelWatcher` / adb çalıştırıcı yoluyla `adb -s <seri> forward tcp:<yerel> tcp:<port>` (yerel port: 47010 doluysa boş bir port). OFF, oturum sonu, USB kaybı, BYE (HOST_SLEEP dahil), uygulama kapanışı: `adb forward --remove`, bağlı birim ayrılır (`NetFSUnmount`/`unmount`; açık dosya varsa zorlamadan dene, başarısızsa logla). Wi-Fi oturumunda READY saklanır, forward kurulmaz.
- [x] Menü çubuğu: "Tablet dosyalarını aç" (READY + USB + forward hazırken etkin). Seçilince WebDAV birimi `NetFSMountURLAsync` ile `http://localhost:<yerel>/` adresine `matebridge` / jeton ile bağlanır (kimlik bilgisi URL'ye gömülmez, anahtarlığa kaydedilmez, UI istemi çıkmaz — `kNetFSUseAuthenticationInfoKey`/`kNAUIOptionNoUI` vb.), sonra Finder'da açılır. Birim adı "MatePad" olsun (mümkünse). Zaten bağlıysa yalnızca Finder'da açar. Wi-Fi'de menü öğesi devre dışı, yanında "(yalnızca USB ile)". Erişim/izin yoksa (tablet OFF) öğe gizli ya da "Tablette açın: Ayarlar → Tablet dosyaları".
- [x] Jeton ve kimlik bilgisi hiçbir yerde loglanmaz/saklanmaz (yalnızca bellek). Log: `component=files ev=forward state=on|off`, `ev=mount result=ok|error code=…`, `ev=unmount`.
- [x] Saf mantık testli (FILES_INFO durum makinesi: ne zaman forward/mount/unmount). `./scripts/check.sh` geçiyor — **not:** Android tarafı fixture testi T-135 birleşene kadar kırmızı olabilir.

## Kapsam dışı

Cihaz testi, host'u çalıştırma (orkestratör).

## Plan

1. **Protokol (Core):** `Protocol/FilesMessages.swift`: `FilesInfo` (`state` açık kod, bilinmeyen → OFF; `port` u16; `token` str8). `description`/`debugDescription` jetonu gizler. `MessageType.filesInfo = 0x09`, `Message.filesInfo`, `Capabilities.files` (bit10). `SessionMachine`: ACCEPTED'da `.deliver`, öncesinde yok sayılır. `FixtureTests`'e `files_info_ready`, `files_info_off`; codec testleri (bilinmeyen state, kısa payload).
2. **Saf mantık (Core, `Files/`):**
   - `TabletFilesPlanner`: olaylar `sessionStarted(transport, capable)`, `filesInfo`, `sessionEnded`, `usbLost`/`usbBack`, `shutdown`, `retry` (menü açılınca), `forwardFinished(gen, localPort?)`, `openRequested`, `mountFinished(gen, path?/error)`. Eylemler: `installForward(remotePort, gen)`, `unmount(localPort)`, `removeForward(localPort)`, `mountAndReveal(localPort, token, gen)`, `reveal(path)`. Menü durumu: `hidden`, `enableOnTablet`, `usbOnly`, `preparing`, `ready(lastFailed)`, `mounting`. Kural: READY+USB → forward; Wi-Fi'de READY saklanır, forward yok; OFF/oturum sonu/USB kaybı/kapanış → önce unmount sonra forward kaldır; port değişirse yeniden forward, jeton değişirse birim ayrılır; eski kuşağın (gen) geç gelen başarılı sonucu geri alınır (yetim forward/birim kalmaz).
   - `WebDavMount`: `http://localhost:<yerel>/` URL'si; bağlama tablosu satırının bizim birim olup olmadığı (`webdav`, localhost/127.0.0.1, port). `AdbOutput.parseForwardPort` (`adb forward tcp:0` çıktısı).
3. **Host (`Files/TabletFilesBridge.swift`):** kendi seri kuyruğu; planner eylemlerini yürütür: `adb -s <seri> forward tcp:47010 tcp:<port>`, olmazsa `tcp:0` (adb boş port verir); `forward --remove`; `NetFSMountURLAsync` (kullanıcı `matebridge`, parola jeton; `kNAUIOptionNoUI`, `kNetFSAllowLoopbackKey`; URL'de kimlik yok, anahtarlık yok); zaten bağlıysa `getmntinfo` ile bulup yalnızca Finder'da açar; ayırma `unmount(path, 0)` (zorlamasız, hata loglanır). adb yolu/çalıştırıcısı `UsbTunnelWatcher` ile ortak (`AdbBinary.locate()` olarak ayrılır). Kapanışta sınırlı süre (≈3 sn) bekleyen eşzamanlı temizlik. Log: `component=files ev=forward state=on|off`, `ev=mount result=ok|error code=…`, `ev=unmount`; jeton/seri/yol loglanmaz.
4. **Menü (`main.swift`):** "Tablet dosyalarını aç" öğesi planner menü durumuna göre (gizli / devre dışı + "(yalnızca USB ile)" / "Tablette açın: Ayarlar → Tablet dosyaları" / hazırlanıyor / etkin). `sessionStarted`/`sessionEnded`/`deliver`/USB izleyici durumu köprüye bağlanır; `applicationWillTerminate`'de `shutdown`.
5. Testler: planner durum makinesi, URL/bağlama eşleme, forward port ayrıştırma, fixture.

## Handoff

- **Commit:** `f80f784` (uygulama) + `591e6bf` (orkestratör kararı: `127.0.0.1` ve `/MatePad/`), plan `5965df0`. Dal `task/T-136-host-files-mount`, `e73df47` üzerinden.
- **check.sh:** host-mac build + test, probe'lar, fixture/crypto güncellik kontrolleri yeşil. Tek kırmızı: Android `FixtureTest` (`files_info_ready`, `files_info_off` için Kotlin tarafı yok, T-135 bekleniyor). Beklenen durum.
- **Dokunulan dosyalar:**
  - Core: `Protocol/FilesMessages.swift` (yeni: `FilesState`, `FilesInfo`, jetonu gizleyen `description`), `ProtocolConstants.swift` (`filesInfo = 0x09`), `Message.swift`, `Messages.swift` (`Capabilities.files` bit10), `Session/SessionMachine.swift` (FILES_INFO yalnızca ACCEPTED'da `.deliver`), `Input/InputStateMachine.swift` (switch tamlığı), `Usb/AdbOutput.swift` (`parseForwardPort`), `Files/TabletFilesPlanner.swift` (yeni, saf durum makinesi + `FilesSecret`), `Files/WebDavMount.swift` (yeni: URL, bağlama tablosu eşleme).
  - Host: `Files/TabletFilesBridge.swift` (yeni yürütücü), `Usb/AdbBinary.swift` (yeni; adb yolu/ortamı/zaman aşımı `UsbTunnelWatcher` ile ortak), `Usb/UsbTunnelWatcher.swift` (yalnızca `AdbBinary`'yi kullanacak şekilde; davranış aynı).
  - App: `main.swift` (menü öğesi, `NSMenuItemValidation` ile etkinlik, oturum/deliver/USB/kapanış bağlantıları).
  - Testler: `Files/TabletFilesPlannerTests.swift` (yeni), `CodecTests`, `FixtureTests` (+2 fixture), `SessionMachineTests`, `AdbOutputTests`.
- **Davranış özeti:** READY + USB → `adb -s <seri> forward tcp:47010 tcp:<port>`, olmazsa `tcp:0` (adb boş port seçer, çıktıdan okunur). Wi-Fi'de READY saklanır, forward yok, menü "(yalnızca USB ile)" devre dışı. OFF / bilinmeyen state / oturum sonu (BYE, HOST_SLEEP dahil) / USB izleyici `no_device`/`no_adb` / uygulama kapanışı → önce `unmount(path, 0)` (zorlamasız; hata `code=errno` ile loglanır), sonra `forward --remove`. Aynı port + yeni jeton → yalnızca birim ayrılır, forward kalır. Port değişirse yeniden forward. Kuşak (generation) numarası: oturum bittikten sonra biten mount/forward geri alınır. Forward başarısızsa menü "hazırlanıyor…" kalır, menü her açılışta yeniden dener. Mount: `NetFSMountURLAsync(http://127.0.0.1:<yerel>/MatePad/, mountpath nil, "matebridge", jeton, {UIOption: NoUI, AllowLoopback: true}, {SoftMount: true})`, sonra `NSWorkspace.open(mountpoint)`. Zaten bağlıysa (`getfsstat`, `webdav` + 127.0.0.1:<yerel>, yol fark etmez) yalnızca Finder açılır. Kapanışta en fazla 3 sn beklenir.
- **Menü durumları:** gizli (oturum yok / istemci FILES yeteneği yok ve FILES_INFO göndermedi), "Tablet dosyaları: tablette açın (Ayarlar → Tablet dosyaları)" (USB + OFF), "Tablet dosyalarını aç (yalnızca USB ile)" (Wi-Fi), "… (hazırlanıyor…)", "Tablet dosyaları bağlanıyor…", "Tablet dosyalarını aç" (etkin), son deneme başarısızsa "(bağlanamadı, tekrar dene)".
- **Loglar:** `component=files ev=info state=ready|off port=…`, `ev=forward state=on local=… remote=…` / `state=off local=… result=ok|error` / `state=failed reason=…`, `ev=mount result=ok ms=…` / `result=error code=… ms=…` (`already=1` zaten bağlıysa), `ev=unmount result=ok|error code=…`. Jeton, cihaz serisi, bağlama yolu loglanmaz. Jeton yalnızca bellekte (planner `info`, `FilesSecret`).
- **Varsayımlar:** NetFS, kullanıcı/parola argümanla verilip UI kapalıyken kimlik bilgisini anahtarlığa yazmaz. NetFS CFSTR sabitleri Swift'e gelmediği için düz dizgilerle verildi ("UIOption"/"NoUI", "AllowLoopback", "SoftMount"; NetFS.h'deki değerlerle aynı). Birim URL'si `http://127.0.0.1:<yerel>/MatePad/`; T-135 sunucusu kökü `/MatePad/` altında da sunar (orkestratör kararı), birimin "MatePad" adını alması beklenir. Her yerde IPv4 `127.0.0.1` (adb forward yalnızca IPv4 dinler); `localhost` kullanılmaz ve eşlenmez.
- **Test EDİLMEDİ (cihaz/izin gerekir):** gerçek `adb forward` ve 47010 doluyken `tcp:0` yolu; NetFS'in localhost WebDAV'ı (Digest/Basic) sorunsuz bağlaması, anahtarlığa kayıt yapmadığı ve hiç pencere çıkmadığı; Finder'da açılma; açık dosya varken ayırmanın başarısız olup loglanması; kablo çekilince/HOST_SLEEP'te ayırma süresi (webdavfs sunucu yokken `unmount` gecikebilir; kendi kuyruğunda çalışır, ana iş parçacığını bloklamaz); Wi-Fi'de menü metni.

### Open questions

1. ~~Birim adı "MatePad"~~ — çözüldü (orkestratör): URL `http://127.0.0.1:<port>/MatePad/`, T-135 sunucusu `/MatePad/` önekini köke eşler. Cihazda birim adının gerçekten "MatePad" olduğu doğrulanmalı.
2. ~~`localhost` → `::1`~~ — çözüldü (orkestratör): her yerde `127.0.0.1`.
