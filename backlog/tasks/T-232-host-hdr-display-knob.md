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

1. **Saf mantık (MateBridgeCore, yeni dosya `Video/VirtualDisplayTransfer.swift`):**
   - `VirtualDisplayTransfer.parse(_ raw: String?) -> (requested: UInt32, invalid: Bool)`: yok/boş → 0; `"0"` → 0; `"1"` → 1; başka her değer → 0 + `invalid` (sessizce SDR, bugünkü davranış).
   - `VirtualDisplayTransfer.decide(requested:, selectorAvailable:) -> Decision` (`.legacy` | `.transfer(UInt32)` | `.fallback(reason)`): requested 0 → `.legacy` (eski `initWithWidth:height:refreshRate:` çağrısı, bit-bit aynı); 1 + seçici var → `.transfer(1)`; 1 + seçici yok → `.fallback("selector_missing")`. Mod nesnesi nil dönerse ya da `applySettings:` reddederse çağıran `.fallback("mode_nil"/"settings_rejected")` ile eski yola bir kez döner.
   - `logFields(requested:applied:reason:edrMax:edrPotential:)`: `requested= applied= [reason=] edr_max= edr_potential=` (EDR değerleri `%.2f`, yoksa `na`).
   - `StreamProfileLog.knobAllowList`'e `MATEBRIDGE_VD_TRANSFER` (`ev=profile knobs=`'ta görünsün; KNOBS.md "geliştirici sınıfı").
2. **VirtualDisplay.swift (özel API yalnız burada):** `init`'e `transferFunction: UInt32 = 0` parametresi. `.legacy` yolunda mevcut kod değişmez. `.transfer` yolunda `initWithWidth:height:refreshRate:transferFunction:` (IMP, `(UInt32, UInt32, Double, UInt32)`); mod nil ise eski seçiciyle yeniden dener. `applySettings:` tf'li modlarla reddedilirse aynı display nesnesine eski modlarla bir kez daha uygular. Sonuç `transferApplied`/`transferFallbackReason` özelliklerinde. `DisplayMode` değişmez (env süreç boyunca sabit, yeniden kullanım kararı etkilenmez).
3. **VideoPipeline.swift (`Video/`):** `obtainDisplay` env'den knob'u okur, `VirtualDisplay(... transferFunction:)`'a geçirir.
4. **EDR okuma + log:** `NSScreen` (AppKit, ana iş parçacığı) ile `displayID`'ye eşleşen ekranın `maximumPotentialExtendedDynamicRangeColorComponentValue` / `maximumExtendedDynamicRangeColorComponentValue`. `StreamCoordinator.createPipeline` ekran yeni kurulunca (`display_created`) ve oyun modu ekran değişiminde (yeni ekran = aynı yol) `ev=vd_transfer requested= applied= [reason=] edr_max= edr_potential=` yazar. EDR okuması `await MainActor.run` içinde, kısa.
5. **Testler (`Tests/MateBridgeCoreTests/Video/VirtualDisplayTransferTests.swift`):** parse (nil/""/"0"/"1"/" 1 "/"2"/"abc"), decide (tüm dallar), logFields biçimi, allow-list'te knob ve `knobsField` çıktısı.
6. **Belgeler:** `docs/KNOBS.md` yeni host satırı (yalnızca geliştirici, varsayılan 0, T-232; kaldıran/benimseyen kart: HDR akış kartı B ya da cihaz sonucu olumsuzsa kaldır); `docs/LOGGING.md` `ev=vd_transfer` alanları.
7. `./scripts/check.sh`, Handoff, `status: review`.

**Durum (2026-10-05, ajan):** Plan yazıldı; kodlamaya başlanmadı. Kapsam sorusu nedeniyle durdu, bkz. *Açık sorular*.

## Açık sorular

1. **`files:` listesinde MateBridgeCore yok.** Kabul kriteri "[XCTest] knob ayrıştırma ve geri dönüş kararı saf fonksiyon olarak test edilir" diyor; ancak tek test hedefi `MateBridgeCoreTests` yalnız `MateBridgeCore`'a bağlı (`Package.swift`), yani `MateBridgeHost` içindeki bir fonksiyon test edilemez. Ayrıca "host `knobs=` profil alanı" düzenine uymak `StreamProfileLog.knobAllowList`'i (`host-mac/Sources/MateBridgeCore/Video/EncoderKnobs.swift`) değiştirmeyi gerektiriyor. Önerilen ek dosyalar:
   - `host-mac/Sources/MateBridgeCore/Video/VirtualDisplayTransfer.swift` (yeni, saf mantık)
   - `host-mac/Sources/MateBridgeCore/Video/EncoderKnobs.swift` (yalnız allow-list'e bir satır)
   Onaylanırsa yukarıdaki plan aynen uygulanır. (Alternatif `Package.swift`'e `MateBridgeHostTests` hedefi eklemek; daha büyük değişiklik, önermiyorum.)

## Handoff

_(Ajan bitirince doldurur.)_
