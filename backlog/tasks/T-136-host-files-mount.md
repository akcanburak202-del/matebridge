---
id: T-136
title: Mac — FILES_INFO ile adb forward, WebDAV birimini bağla, menü "Tablet dosyalarını aç"
status: in-progress
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

- [ ] Protokol: `FILES_INFO` çözme/kodlama, `FixtureTests`'e iki fixture.
- [ ] READY + oturum USB: mevcut `UsbTunnelWatcher` / adb çalıştırıcı yoluyla `adb -s <seri> forward tcp:<yerel> tcp:<port>` (yerel port: 47010 doluysa boş bir port). OFF, oturum sonu, USB kaybı, BYE (HOST_SLEEP dahil), uygulama kapanışı: `adb forward --remove`, bağlı birim ayrılır (`NetFSUnmount`/`unmount`; açık dosya varsa zorlamadan dene, başarısızsa logla). Wi-Fi oturumunda READY saklanır, forward kurulmaz.
- [ ] Menü çubuğu: "Tablet dosyalarını aç" (READY + USB + forward hazırken etkin). Seçilince WebDAV birimi `NetFSMountURLAsync` ile `http://localhost:<yerel>/` adresine `matebridge` / jeton ile bağlanır (kimlik bilgisi URL'ye gömülmez, anahtarlığa kaydedilmez, UI istemi çıkmaz — `kNetFSUseAuthenticationInfoKey`/`kNAUIOptionNoUI` vb.), sonra Finder'da açılır. Birim adı "MatePad" olsun (mümkünse). Zaten bağlıysa yalnızca Finder'da açar. Wi-Fi'de menü öğesi devre dışı, yanında "(yalnızca USB ile)". Erişim/izin yoksa (tablet OFF) öğe gizli ya da "Tablette açın: Ayarlar → Tablet dosyaları".
- [ ] Jeton ve kimlik bilgisi hiçbir yerde loglanmaz/saklanmaz (yalnızca bellek). Log: `component=files ev=forward state=on|off`, `ev=mount result=ok|error code=…`, `ev=unmount`.
- [ ] Saf mantık testli (FILES_INFO durum makinesi: ne zaman forward/mount/unmount). `./scripts/check.sh` geçiyor — **not:** Android tarafı fixture testi T-135 birleşene kadar kırmızı olabilir.

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

(ajan doldurur)
