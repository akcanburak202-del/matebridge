---
id: T-232
title: Host dev knob — create the MateBridge virtual display with an HDR transfer function (tf=1) so games can be checked for an HDR toggle; stream stays SDR
status: todo
phase: 6
owner: mac-host-dev
depends_on: [T-226]
decisions: []
files:
  - host-mac/Sources/MateBridgeHost/VirtualDisplay.swift
  - host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift
  - host-mac/Sources/MateBridgeHost/Video/
  - host-mac/Tests/
  - docs/KNOBS.md
  - docs/LOGGING.md
  - backlog/tasks/T-232-host-hdr-display-knob.md
---

## Amaç

T-226 araştırmasının (docs/research/2026-10-04-hdr-feasibility.md, "kart A") ilk adımı. Kullanıcı 2026-10-05 HDR denemesini onayladı. Soru: MateBridge ekranı HDR (EDR) yetenekli kurulursa macOS ve oyunlar (RE4/GameHub, D3DMetal) HDR seçeneğini açıyor mu? Akış bu kartta **SDR kalır**. Amaç yalnız "Mac tarafı HDR görüyor mu" sorusunu cevaplamak; tabletteki görüntünün HDR modunda soluk ya da yanlış görünmesi beklenen ve kabul edilen bir yan etki.

## Bağlam

- `CGVirtualDisplayMode` `initWithWidth:height:refreshRate:transferFunction:` macOS 27'de var (T-226 Handoff; Sidecar Reference Mode `tf=1` kullanıyor). Özel API yalnız `VirtualDisplay.swift` içinde kalır (AGENTS.md).
- Geliştirici anahtarı: `MATEBRIDGE_VD_TRANSFER=0|1` (varsayılan 0 = bugünkü davranış, bit-bit aynı). Mevcut env-knob düzenine uy (`docs/KNOBS.md`, host `knobs=` profil alanı).
- Yöntem yoksa ya da başarısız olursa eski `initWithWidth:height:refreshRate:`'e geri dön ve logla (`ev=vd_transfer requested=1 applied=0 reason=…`).
- Log: ekran kurulunca `ev=vd_transfer requested= applied=` ve ekranın `NSScreen.maximumPotentialExtendedDynamicRangeColorComponentValue` / `maximumExtendedDynamicRangeColorComponentValue` değerleri (EDR başlığı), oyun mod değişiminde (0029 oyun ekranı) de.
- Mac'te pencere açma. Kurulum ve cihaz denemesini orkestratör yapar.

## Kabul kriterleri

- [ ] [XCTest] Knob ayrıştırma (yok/0/1/geçersiz) ve geri dönüş kararı saf fonksiyon olarak test edilir.
- [ ] Varsayılan yolda `CGVirtualDisplayMode` çağrısı değişmez.
- [ ] `ev=vd_transfer` ve EDR değerleri docs/LOGGING.md'de; knob docs/KNOBS.md'de (geliştirici sınıfı).
- [ ] `./scripts/check.sh` geçer.
- [ ] [device, orkestratör + kullanıcı] `MATEBRIDGE_VD_TRANSFER=1` ile: Sistem Ayarları → Ekranlar'da MateBridge ekranında HDR seçeneği görünüyor mu, EDR başlığı > 1 mi, RE4'te HDR anahtarı açılıyor mu. Sonuç NOTES'a.

## Plan

_(Ajan kodlamadan önce doldurur.)_

## Handoff

_(Ajan bitirince doldurur.)_
