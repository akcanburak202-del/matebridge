---
id: T-006
title: Sabit imza kimliği (Apple Development) ve .app paketleme betiği
status: todo
phase: 0
owner: orchestrator
depends_on: []
decisions: [0002]
files:
  - scripts/bundle-host.sh
  - host-mac/Resources/
---

## Amaç

macOS'un Screen Recording ve Accessibility izinlerini her derlemede sıfırlamaması için uygulamanın hep aynı kimlikle imzalanması.

## Kabul kriterleri

- [ ] Kullanıcı Xcode → Settings → Accounts'ta Apple ID ile giriş yaptı, "Apple Development" sertifikası oluştu (ücretsiz hesap yeterli).
- [ ] `security find-identity -v -p codesigning` kimliği gösteriyor.
- [ ] `scripts/bundle-host.sh`: SwiftPM çıktısını `MateBridge.app` içine koyar, Info.plist ve entitlements ekler, bu kimlikle imzalar.
- [ ] İki ardışık derlemede verilen izinlerin korunduğu doğrulandı.

## Handoff

- **Açık sorular:**
