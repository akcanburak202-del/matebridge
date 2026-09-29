---
id: T-006
title: Sabit imza kimliği (Apple Development) ve .app paketleme betiği
status: done
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

- [x] Kullanıcı Xcode → Settings → Accounts'ta Apple ID ile giriş yaptı, "Apple Development" sertifikası oluştu (ücretsiz hesap yeterli).
- [x] `security find-identity -v -p codesigning` kimliği gösteriyor.
- [x] `scripts/bundle-host.sh`: SwiftPM çıktısını `MateBridge.app` içine koyar, Info.plist ve entitlements ekler, bu kimlikle imzalar.
- [x] İki ardışık derlemede verilen izinlerin korunduğu doğrulandı.

## Handoff

- **Commit:** bu karttaki commit (`task/T-006-signing`)
- **Dokunulan dosyalar:** `scripts/bundle-host.sh`, `host-mac/Resources/Info.plist` (şablon), `host-mac/Resources/MateBridge.entitlements` (boş, sandbox ve hardened runtime yok).
- **Nasıl çalışır:** `swift build` → `build/<Name>.app` (Info.plist şablonu doldurulur, CFBundleVersion = zaman damgası) → keychain'deki ilk geçerli "Apple Development" kimliğiyle imzalanır (`MATEBRIDGE_SIGN_IDENTITY` ile değiştirilebilir). Kimlik adı e-posta içerdiği için repoya yazılmaz. Varsayılan ürün `host-mac` / `MateBridgeApp` (henüz yok). `--package/--product/--name/--bundle-id` ile problar da paketlenebilir.
- **Doğrulama (2026-09-29):** vdisplay-probe `MateBridgeVDisplayProbe.app` (`dev.matebridge.probe.vdisplay`) olarak paketlendi. `open` ile başlatınca kendi TCC kimliğiyle çalıştı (Terminal'in izni geçmedi, çıkış 77). Kullanıcı Ekran Kaydı iznini uygulamaya verdi. Ardından debug → release → debug olarak iki kez yeniden paketlendi. Üç farklı CDHash'in hepsinde izin korundu, sanal ekran açıldı ve kareler yakalandı. Designated requirement: `identifier … and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: …" and certificate 1[…] exists`, yani ikiliye değil kimliğe bağlı.
- **Varsayımlar:** Ücretsiz Apple hesabı sertifikası 1 yıl geçerli (2027-09-29). Süre dolunca yenilenen sertifikanın CN'i aynı kalırsa izinler korunur, değişirse bir kez yeniden izin gerekir.
- **Test edilmeyenler:** Accessibility izninin paketli uygulamada korunması ayrıca denenmedi (aynı TCC mekanizması). Menü çubuğu uygulaması (LSUIElement) henüz yok.
- **Açık sorular:** `open` ile başlatılan uygulamanın çalışma dizini `/`. Ürün kodu göreli yol kullanmamalı (probun `out/` PNG kaydı bu yüzden başarısız oldu). `host-mac/AGENTS.md`'deki "added in a later task" notu artık güncel değil, host iskeleti görevinde düzeltilmeli.
