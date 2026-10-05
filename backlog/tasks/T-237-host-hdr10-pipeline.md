---
id: T-237
title: Host — HDR10 per decision 0032 (STREAM_PREFS dynamic_range codec + HDR display, SCK HDR capture, VT Main10 PQ, SDR fallback)
status: review
phase: 6
owner: mac-host-dev
depends_on: [T-232]
decisions: [0032]
files:
  - host-mac/Sources/MateBridgeCore/
  - host-mac/Sources/MateBridgeHost/VirtualDisplay.swift
  - host-mac/Sources/MateBridgeHost/Video/
  - host-mac/Sources/MateBridgeHost/Session/
  - host-mac/Tests/
  - docs/LOGGING.md
  - docs/KNOBS.md
  - backlog/tasks/T-237-host-hdr10-pipeline.md
---

## Amaç

Decision 0032'nin host tarafı. Protokol (PROTOCOL.md §0x03 HDR10 notu, §0x05 `dynamic_range` grubu ve host kuralı) ve fixture'lar (`stream_prefs_hdr`, `stream_config_hdr10`, `invalid_stream_prefs_hdr_partial`) orkestratörün `task/T-236-hdr-protocol` dalında. **Bu dalın üzerine kur** (`git checkout -b task/T-237-host-hdr10 task/T-236-hdr-protocol`). Protokolü değiştirme; uyuşmazlık görürsen kartın Açık sorular'ına yaz.

## Bağlam

- Codec: `STREAM_PREFS` 8 / 12 / ≥14 bayt, 9–11 ve 13 kısa; fixture testleri (her fixture'ın test kaydı: `FixtureTests.everyFixtureFileHasATestCase`). `StreamPrefsPolicy`/`StreamPrefsStore` (cihaz başına hatırlanan tercih, T-049) `dynamic_range`'i de tutar.
- Ekran: `dynamic_range=1` → T-232'deki `transferFunction=1` yolu (`VirtualDisplay`, özel API yalnız orada), ekran kipi değişimi gibi yeniden kurma. Oyun ekranı (0029) ile birlikte çalışır.
- Yakalama: SCK HDR — araştırma §2 ve `probes/hdr-probe/Sources/hdr-probe/Capture.swift` (`captureDynamicRange`, `x420`, `colorSpaceName` itur_2100_PQ). Kodlama: `probes/hdr-probe/Sources/hdr-probe/EncodeBench.swift` (Main10 PQ, MDCV/CLL, `HDRMetadataInsertionMode`, hızlı profil; 120 fps p50 5,6 ms ölçüldü). Girdi etiketlerini 2020/PQ/2020'ye yeniden yaz (T-113 `HEVCEncoder` deseni). Meta veri değerleri: MDCV P3-D65 1000 nit (prob değerleri), CLL 1000/400 başlangıç; planda gerekçelendir.
- `STREAM_CONFIG`: HDR uygulanınca 9/16/9/0, değilse bugünkü SDR kodları.
- Geri dönüş: ekran tf=1 reddi, SCK HDR hatası, VT Main10/PQ reddi → SDR yoluna dön, `ev=hdr_fallback reason=`, STREAM_CONFIG SDR kodları. `ev=hdr_config requested= applied= …` her yapılandırmada.
- `MATEBRIDGE_VD_TRANSFER` geliştirici anahtarı kalır (SDR akışla HDR ekran), `dynamic_range=1` onu gerektirmez.
- Pencere açma, çalışan host'a ve tablete dokunma. Cihaz kabulünü orkestratör yapar.

## Kabul kriterleri

- [ ] [XCTest] Üç yeni fixture decode/encode ve hata; eski fixture'lar değişmez; `dynamic_range` bilinmeyen değer → 0.
- [ ] [XCTest] Politika: istek + yetenek → HDR yapılandırması; her geri dönüş nedeni → SDR + doğru `reason`; `dynamic_range` değişimi yeni `config_id` ve ekran yeniden kurma kararı; hatırlanan tercih `dynamic_range`'i taşır.
- [ ] Varsayılan (SDR) yol bit-bit aynı.
- [ ] `ev=hdr_config`, `ev=hdr_fallback` docs/LOGGING.md'de.
- [ ] `./scripts/check.sh` geçer (istemci tarafı fixture testleri T-238'de; bu dalda Android fixture testleri yeni dosyalar için düşebilir — yalnız host kısmının geçtiğini Handoff'a yaz).

## Plan

1. **Codec (Core, `Messages.swift`):** `StreamPrefs.dynamicRange: UInt8` (ham tel değeri). Yazma: ekran grubu `display ≠ 0×0 || dynamicRange ≠ 0` ise, dinamik aralık grubu (`dynamic_range`, `reserved=0`) yalnız `dynamicRange ≠ 0` ise. Okuma: 8 → yok, 12 → ekran grubu, ≥14 → iki grup (fazlası yok sayılır), 9–11/13 → `payloadTooShort`. `normalized`: `{0,1}` dışı → 0. `DynamicRange` enum (`sdr`/`hdr10`, `init(wire:)`).
2. **Ayarlar ve politika (Core):** `VideoSettings.dynamicRange` (varsayılan `.sdr`), `applying(_:…, allowHDR:)` / `initialSettings(…allowHDR:)`. `HDRPolicy.decide(requested:codec:allowed:)` → `.sdr` / `.hdr10` / `.fallback(reason)` (`codec_not_hevc`, `disabled`). `streamConfig`: HDR10'da 9/16/9/0, aksi halde bugünkü 1/13/1/1 (SDR bit-bit aynı). `HDRFallback` (`GameDisplayFallback` deseni): çalışma anı hatası (`display_rejected`, `capture_failed`, `encoder_rejected`) → süreç boyunca HDR kapalı (tekrar eden döngü olmasın; oyun ekranı geri dönüşüyle aynı kural), `revalidated` ile kuyruktaki oturum başlangıcı da düzeltilir. `GameDisplayFallback.revalidated` `allowHDR` alır (HDR'yi geri açmasın).
3. **Ekran kimliği:** `DisplayMode.transfer` (istenen tf; HDR10 → 1, yoksa `MATEBRIDGE_VD_TRANSFER` değeri, `VideoSettings.vdTransfer` olarak `applyingExperimentKnobs`'ta okunur). `DisplayReuse` tf farkında `recreate(.transferChange)` (`ev=display_recreate reason=transfer_change`). Böylece `dynamic_range` değişimi ekranı yeniden kurar; geliştirici anahtarı açıkken tf zaten 1 olduğundan yeniden kurmaz. `DisplayLease` değişmez (ayarlar farklı → `.reconfigure`).
4. **Meta veri (Core):** `HDR10Metadata` (prob `HDRProbeCore.HDR10Static`'ten): MDCV P3-D65, tepe 1000 nit, taban 0,0001 nit; CLL MaxCLL 1000 / MaxFALL 400. Gerekçe: Mac HDR sanal ekranı ~5× EDR başlık (SDR beyaz ~140–203 nit → tepe ~700–1000 nit), gamut P3 (ekran P3 primerleriyle kuruluyor); gerçek zamanlı içerikte ölçülmüş CLL yok, 1000 tepe için güvenli üst sınır, 400 FALL oyun içeriği için yaygın değer. Tablet (500 nit) ton eşlemesini bu tavana göre yapar; cihazda gerekirse değiştirilir. Bayt düzeni testle sabitlenir.
5. **Host halkaları:** `VideoPipeline` HDR'de: `HEVCEncoder` Main10 + 2020/PQ/2020 + MDCV/CLL + `HDRMetadataInsertionMode=Auto` (herhangi biri reddedilirse `HDRSetupError(.encoderRejected)`), girdi etiketleri oturumun HDR etiketlerine yeniden yazılır (T-113 deseni, etiketler ayara göre). `VirtualDisplay` HDR'de tf=1 ile kurulur (yalnız `VirtualDisplay` özel API'ye dokunur; istek `Knob(1)` olarak verilir), `transferOutcome.applied ≠ 1` → `HDRSetupError(.displayRejected, detail)`. `ScreenCapture` HDR'de `captureDynamicRange=.hdrCanonicalDisplay`, `x420`, `itur_2100_PQ`, matris 2020 (macOS 27'de `captureHDRRecordingPreservedSDRHDR10` preset'iyle aynı değerler, okundu); `displayNotFound` ve ekran uykusu SCK hataları (`DisplayWaker.reason ≠ nil`) HDR hatası sayılmaz, diğerleri `HDRSetupError(.captureFailed)`.
6. **Koordinatör:** her `applying` çağrısı `allowHDR` geçirir. `createPipeline` hatasında önce HDR geri dönüşü (`ev=hdr_fallback reason=… detail=…`, W), tercih HDR'siz yeniden uygulanır, yeni `config_id` + `onReconfigure`, SDR ekran kurulur (oyun ekranı geri dönüşüyle aynı akış). Her başarılı işlem hattı başında `ev=hdr_config requested= applied= [reason=] primaries= transfer= matrix= full_range= display_transfer= config_id=`. Politika düzeyinde düşüş (`codec_not_hevc`, `disabled`) de `hdr_config`'in `reason`'ında. `ev=stream_prefs`'e `dynamic_range=` alanı; oturum başlangıcı yeniden bildirim nedenine `hdr_off`.
7. **Hatırlanan tercih:** `StreamPrefsStorageCodec` 6. değer `dynamic_range` (yalnız ≠0 iken; yoksa 3/5 değerli kayıt değişmez). Eski build 6 değerli kaydı okuyamaz → varsayılan mod (zararsız).
8. **Testler:** üç yeni fixture (FixtureTests), codec kenarları (13 bayt kısa, bilinmeyen değer → 0, eski fixture'lar değişmez), politika (istek+yetenek → HDR; her neden → SDR + reason; tf değişimi → yeniden kurma; yeni config_id; saklama), meta veri baytları, log alanları, SDR `streamConfig`/ayarların değişmediği.
9. **Belgeler:** LOGGING.md (`hdr_config`, `hdr_fallback`, `display_recreate reason=transfer_change`, `stream_prefs dynamic_range=`), KNOBS.md #43 notu (`dynamic_range=1` anahtarı gerektirmez).

## Handoff

**Commit:** `3778ca6` (uygulama; plan `e61063d`), dal `task/T-237-host-hdr10` (`task/T-236-hdr-protocol` üstünde). Push/merge yok.

**Dosyalar:**
- Core: `Messages.swift` (`StreamPrefs.dynamicRange`, `DynamicRange`), yeni `Video/HDRPolicy.swift` (`HDRPolicy`, `HDRFallbackReason`, `HDRFallback`, `HDR10Metadata`, `SessionColorTags`, `HDRLog`), `VideoSettings.swift` (`dynamicRange`, `vdTransferKnob`, `displayTransfer`, HDR10 `streamConfig` kodları), `StreamPrefsPolicy.swift` / `StreamPrefsStore.swift` (`allowHDR`, 6 değerli kayıt), `GameDisplayPolicy.swift` (`DisplayMode.transfer`, `DisplayReuse.transferChange`, `revalidated(allowHDR:)`).
- Host: `VirtualDisplay.swift` (yalnız `mode.transfer` + yorum; özel API dokunuşu değişmedi, tf istek değeri ayardan gelir), `Video/VideoPipeline.swift` (`HDRSetupError`, ekran `applied≠1` ve SCK hata sınıflaması), `Video/HEVCEncoder.swift` (Main10, 2020/PQ/2020, MDCV/CLL, `HDRMetadataInsertionMode=Auto`, ayara göre retag), `Video/ScreenCapture.swift` (HDR yapılandırması), `Video/VideoDump.swift` (knob'u env'den okumaya devam), `Session/StreamCoordinator.swift` (`allowHDR` her türetmede, `fallBackFromHDR`, `ev=hdr_config`/`hdr_fallback`, `display_recreate reason=transfer_change`, `stream_prefs`/`stream_reconfigure` alanları, `hdr_off` yeniden bildirim), `Session/UserDefaultsStreamPrefsStore.swift` (yorum).
- Testler: yeni `Video/HDRTests.swift` (21 test), `FixtureTests.swift` (3 yeni fixture), `CodecTests.swift` ve `GameDisplayTests.swift` (protokol değişiminin gerektirdiği güncelleme: 12. bayttan sonraki "fazlalık" baytlar artık dinamik aralık grubu; 6 değerli kayıt artık geçerli).
- Belgeler: `docs/LOGGING.md` (yeni "HDR10 akış" bölümü, `display_recreate`, `vd_transfer`), `docs/KNOBS.md` #43.

**check.sh:** host (swift build + 814 swift-testing / 476 XCTest), tüm Swift problar, Android problar, protokol fixture/crypto/belge kontrolleri, ölçüm kiti: **geçti**. **Düşen tek şey** `client-android` `FixtureTest.everyFixtureHasATestCase` (3 yeni fixture'ın Kotlin test kaydı yok; T-238'in işi, kartta öngörüldüğü gibi). `--only host,protocol`: ALL OK.

**Doğrulanan (sentetik, ekran/akış yok):** HEVCEncoder'ın HDR özellik kümesinin aynısı (hızlı profil, 1848×1214, 30 sentetik `x420` kare) VT'de: tüm `VTSessionSetProperty` `0`, 30/30 kare, donanım kodlayıcı, çıktı biçimi `ITU_R_2020/SMPTE_ST_2084_PQ/ITU_R_2020`, `FullRangeVideo=0`, `BitsPerComponent=10`, MDCV/CLL baytları beklenen (`33c286c4…00000001`, `03e80190`), SPS profil 2 (Main10). SCK preset değerleri (yakalamasız okuma): `captureHDRRecordingPreservedSDRHDR10` = `x420`, `kCGColorSpaceITUR_2100_PQ`, `captureDynamicRange=2` (`hdrCanonicalDisplay`) — kod bu değerleri tek tek kuruyor.

**Varsayımlar:**
- HDR geri dönüşü süreç boyunca (oyun ekranı T-214 kuralıyla aynı); host yeniden başlayınca HDR tekrar denenir. Politika düzeyindeki düşüşler (`codec_not_hevc`, `disabled`) yeni `config_id` gerektirmez (ayarlar zaten SDR türetilir), yalnız `hdr_config reason=` yazar.
- Host `dynamic_range=1`'i oyun ekranı şartı olmadan da uygular (doğal ekranda da); "yalnız Oyun modu" istemcinin kuralı (karar 0032).
- SCK hatalarından ekran uykusuyla açıklananlar (`DisplayWaker.reason ≠ nil`) ve `displayNotFound` HDR hatası sayılmaz (yanlışlıkla HDR'yi kapatmasın); yalnız kurulum anı hataları geri dönüş tetikler. Çalışırken (kurulumdan sonra) oluşan kodlama hataları bugünkü `pipeline_failed`/retry yolunda kalır.
- `MATEBRIDGE_VD_TRANSFER=1` açıkken ekran tf=1 kalır, SDR ↔ HDR10 geçişi ekranı yeniden kurmaz (yalnız yakalama+kodlayıcı); anahtar kapalıyken geçiş `display_recreate reason=transfer_change` ile ekranı yeniden kurar.
- Meta veri: MDCV P3-D65 1000/0,0001 nit, CLL 1000/400 (gerekçe Plan 4'te). Cihazda ton eşleme kötü görünürse yalnız `HDR10Metadata.host` değişir.
- Eski build 6 değerli hatırlanan tercih kaydını okuyamaz → o cihaz için varsayılan mod (yalnız HDR açıkken kaydedilmişse; zararsız).

**Gerçek donanımda / izinle doğrulanacaklar (orkestratör):**
1. T-238 istemcisiyle Oyun modunda HDR Açık: `ev=hdr_config requested=1 applied=1 … transfer=16`, `vd_transfer requested=1 applied=1 edr_potential≈5`, `encoder_config … profile=main10`, `input_retag` satırı çıkıyor mu (çıkarsa SCK etiketleri oturumunkinden farklı demek: `from=` değerini not et).
2. SCK'nin HDR sanal ekrandan gerçekten `x420` + PQ verdiği, kare hızı (120 fps oyun ekranında `cadence`), enc ms (`latency`) — ilk gerçek HDR yakalama ölçümü bu olacak.
3. HDR Kapalı ↔ Açık geçişi: `stream_reconfigure dynamic_range=sdr->hdr10`, `display_recreate reason=transfer_change`, yeni `config_id`; Mac'te pencereler kısa süre yedek ekrana taşınır (oyun ekranı geçişiyle aynı).
4. SDR varsayılan yolun değişmediği: HDR kapalıyken `encoder_config`/`profile` satırları ve renk etiketleri öncekiyle aynı.
5. Geri dönüş yolu cihazda tetiklenmedi (VT/SCK/ekran reddi yapay olarak üretilemedi); kod yolu `game_display_failed` ile aynı desende.

**Açık sorular:**
- Yok (protokol uyuşmazlığı görülmedi). Not: `CodecTests`'teki iki eski beklenti 12. bayttan sonrasını "yok sayılan fazlalık" olarak kullanıyordu; 0032 bu baytları dinamik aralık grubuna çevirdiği için test girdileri `0,0` grubu + fazlalık olacak şekilde güncellendi (davranış PROTOCOL.md ile uyumlu).
