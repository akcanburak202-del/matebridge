---
id: T-232
title: Host dev knob — create the MateBridge virtual display with an HDR transfer function (tf=1) so games can be checked for an HDR toggle; stream stays SDR
status: done
phase: 6
owner: mac-host-dev
depends_on: [T-226]
decisions: []
files:
  - host-mac/Sources/MateBridgeHost/VirtualDisplay.swift
  - host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift
  - host-mac/Sources/MateBridgeHost/Video/
  - host-mac/Sources/MateBridgeCore/Video/VirtualDisplayTransfer.swift
  - host-mac/Sources/MateBridgeCore/Video/EncoderKnobs.swift
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

- [x] [XCTest] Knob ayrıştırma (yok/0/1/geçersiz) ve geri dönüş kararı saf fonksiyon olarak test edilir.
- [x] Varsayılan yolda `CGVirtualDisplayMode` çağrısı değişmez.
- [x] `ev=vd_transfer` ve EDR değerleri docs/LOGGING.md'de; knob docs/KNOBS.md'de (geliştirici sınıfı).
- [x] `./scripts/check.sh` geçer.
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

**Durum (2026-10-05, ajan):** Plan yazıldı. Kapsam sorusu orkestratörce onaylandı (aşağı), uygulama başladı.

## Açık sorular

1. **`files:` listesinde MateBridgeCore yok.** Kabul kriteri "[XCTest] knob ayrıştırma ve geri dönüş kararı saf fonksiyon olarak test edilir" diyor; ancak tek test hedefi `MateBridgeCoreTests` yalnız `MateBridgeCore`'a bağlı (`Package.swift`), yani `MateBridgeHost` içindeki bir fonksiyon test edilemez. Ayrıca "host `knobs=` profil alanı" düzenine uymak `StreamProfileLog.knobAllowList`'i (`host-mac/Sources/MateBridgeCore/Video/EncoderKnobs.swift`) değiştirmeyi gerektiriyor. Önerilen ek dosyalar:
   - `host-mac/Sources/MateBridgeCore/Video/VirtualDisplayTransfer.swift` (yeni, saf mantık)
   - `host-mac/Sources/MateBridgeCore/Video/EncoderKnobs.swift` (yalnız allow-list'e bir satır)
   Onaylanırsa yukarıdaki plan aynen uygulanır.
   **Cevap (orkestratör, 2026-10-05):** onaylandı; iki dosya `files:` listesine eklendi (`EncoderKnobs.swift` yalnız allow-list satırı). (Alternatif `Package.swift`'e `MateBridgeHostTests` hedefi eklemek; daha büyük değişiklik, önermiyorum.)

## Handoff

- **Commit:** `2a58faf` (uygulama; dalda ayrıca plan `cda7561` ve kapsam notu `2e342bc`). Dal `task/T-232-hdr-display-knob`, `main` `ab765c6` üstünde.
- **check.sh:** ALL OK (host build + test, probes, android, protocol).
- **Dosyalar:**
  - `host-mac/Sources/MateBridgeCore/Video/VirtualDisplayTransfer.swift` (yeni): `parse` (yok/""/0 → 0; 1 → 1; başka → 0 + `invalid`), `decide` (`.legacy`/`.transfer`/`.fallback(selector_missing)`), `fallbackAfterAttempt` (`mode_nil`, `settings_rejected`), `Outcome` (+ `logLevel`: geri dönüş ya da geçersiz değer → `W`), `logFields`, `EDRHeadroom`.
  - `host-mac/Sources/MateBridgeCore/Video/EncoderKnobs.swift`: `knobAllowList`'e `MATEBRIDGE_VD_TRANSFER` (yalnız bu satır + yorumdaki satır no).
  - `host-mac/Sources/MateBridgeHost/VirtualDisplay.swift`: `init(... transfer: VirtualDisplayTransfer.Knob = parse(nil))`; `transferOutcome`. Varsayılan yolda aynı seçici (`initWithWidth:height:refreshRate:`), aynı argümanlar, tek kip. Tek fark sıra: eski kip artık `applySettings:` seçici kontrolünden sonra oluşturuluyor (o seçici yoksa zaten hata atılıyordu).
  - `host-mac/Sources/MateBridgeHost/Video/VideoPipeline.swift`: `obtainDisplay` env'den knob'u geçirir; `displayTransfer` (id + outcome).
  - `host-mac/Sources/MateBridgeHost/Video/DisplayEDR.swift` (yeni): `NSScreen` (`NSScreenNumber` eşleşmesi) → EDR değerleri, `MainActor.run` ile. Pencere açmaz.
  - `host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift`: `display_created`'tan sonra `logDisplayTransfer` → ayrı `Task`'te `ev=vd_transfer` (açılışı bekletmez; sid/gen önceden alınır).
  - `host-mac/Tests/MateBridgeCoreTests/Video/VirtualDisplayTransferTests.swift` (yeni, 13 test).
  - `docs/KNOBS.md` satır 43 (yalnızca geliştirici); `docs/LOGGING.md` `ev=vd_transfer`.
- **Varsayımlar:**
  - `transferFunction:` argümanı `UInt32` (`@convention(c)` imzası `(UInt32, UInt32, Double, UInt32)`), T-226 Handoff'taki imzaya göre. Gerçek tip farklıysa (ör. `int`/`uint32_t` aynı ABI, sorun yok; `NSInteger` olsaydı yine x0..x3 kayıtlarında, arm64'te pratikte uyumlu) cihazda görülür.
  - Reddedilen `applySettings:`'ten sonra aynı `CGVirtualDisplay` nesnesine eski kiple ikinci `applySettings:` çağrısının çalıştığı varsayıldı.
  - `ev=vd_transfer` her yeni ekranda yazılır (varsayılan `requested=0` dahil; SDR temel EDR değerlerini karşılaştırmak için). Korunan (`pipeline_started display=reused`) ekranda yazılmaz. Env süreç boyunca sabit olduğundan `DisplayReuse` kararı etkilenmez.
  - EDR okuması ekran kurulumundan ~1 sn sonra (yakalama başladıktan sonra) yapılır; AppKit ekranı henüz listelemiyorsa `edr_*=na`.
- **Test EDİLMEDİ (cihaz, orkestratör):**
  1. `MATEBRIDGE_VD_TRANSFER=1` ile host başlat: `ev=vd_transfer requested=1 applied=1` mi, yoksa `reason=` ile geri dönüş mü? `ev=profile knobs=MATEBRIDGE_VD_TRANSFER:1` görünüyor mu?
  2. `edr_potential`/`edr_max` > 1,00 mi (MateBridge ekranında macOS EDR başlığı veriyor mu)? Varsayılan koşuda 1,00 bekleniyor; karşılaştırın.
  3. Sistem Ayarları → Ekranlar'da MateBridge ekranında HDR anahtarı görünüyor mu (orkestratör/kullanıcı; Mac'te pencere açmak kullanıcının işi).
  4. Oyun modu (1x oyun ekranı, 0029) geçişinde ikinci `ev=vd_transfer` satırı ve tf'nin 1x kipte de uygulandığı.
  5. RE4/GameHub'da HDR seçeneği açılıyor mu; tablette görüntü (soluk olması beklenen) ve yakalama/encode'un tf=1 ekranda hatasız sürdüğü (SCK 8-bit BGRA, akış SDR).
  6. Varsayılan koşu (`MATEBRIDGE_VD_TRANSFER` yok) eskisiyle aynı: `display_created`, `cadence_setup` `mode_selected=true`.
- **Açık sorular:** yok (kapsam sorusu yukarıda cevaplandı).
