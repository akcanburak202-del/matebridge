---
id: T-136
title: Mac — FILES_INFO ile adb forward, WebDAV birimini bağla, menü "Tablet dosyalarını aç"
status: todo
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

(ajan doldurur)

## Handoff

(ajan doldurur)
