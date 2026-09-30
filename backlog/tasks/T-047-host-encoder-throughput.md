---
id: T-047
title: Mac — HEVC kodlayıcı hız ölçümü (2800×1840'ta 120 fps mümkün mü?) ve ayar denemeleri
status: review
phase: 5
owner: mac-host-dev
depends_on: [T-045]
decisions: []
files:
  - host-mac/Sources/MateBridgeHost/Video/
  - host-mac/Sources/MateBridgeApp/
  - host-mac/Sources/MateBridgeCore/Video/
  - host-mac/Tests/MateBridgeCoreTests/Video/
  - backlog/tasks/T-047-host-encoder-throughput.md
---

## Amaç

NOTES 2026-10-01 "120 fps ölçümü": yakalama 120,0 fps, ama VideoToolbox HEVC kodlayıcısı 2800×1840'ta bugünkü ayarlarla (RealTime, frame reordering kapalı, PrioritizeEncodingSpeedOverQuality, 30 Mbps) ~99 fps'te kalıyor (kodlama 20 ms, `enc_behind` ≈ 21/sn). 120 fps için kodlayıcının saniyede 120 kareye yetişmesi gerekiyor.

## Kabul kriterleri

- [ ] **Tezgâh modu:** `MateBridgeApp --encode-bench [--fps N] [--seconds S] [--config NAME]...`: ekran/SCK olmadan, 2800×1840 BGRA sentetik IOSurface kareler (her karede değişen, gerçekçi içerik: kayan desen + metin) üretip **olabildiğince hızlı** (ve ayrıca `--fps` hızında) kodlar; kodlayıcı çıkış hızını, kare başına süreyi (p50/p95/p99), bit hızını yazar. Kullanıcının ekranına dokunmaz, olay göndermez.
- [ ] **Denenecek yapılandırmalar** (her biri tezgâhta ölçülür, sonuç tablosu Handoff'ta): bugünkü; `RealTime=false`; `MaximizePowerEfficiency=false`; düşük gecikmeli hız denetimi (`kVTVideoEncoderSpecification_EnableLowLatencyRateControl`); `ExpectedFrameRate` 120; farklı `ProfileLevel` (Main/Main10 AutoLevel); 20/30/50 Mbps; ve varsa **iki eşzamanlı oturum** (kareler sırayla iki oturuma, çıktı birleştirme gerekmeden ölçüm için) ya da donanım kodlayıcı sayısı (`VTCopyVideoEncoderList`, `kVTVideoEncoderList_…`).
- [ ] Tezgâhın en iyi yapılandırması 120 fps'e yetişiyorsa `HEVCEncoder`'da bu yapılandırma `MATEBRIDGE_FPS=120` iken kullanılır (60 fps varsayılanı değişmez). Yetişmiyorsa kod değişmez; bulgular Handoff'ta.
- [ ] `./scripts/check.sh` geçiyor. Tezgâh saf olmayan kısım; parametre ayrıştırma testli.

## Kapsam dışı

- Tablet (T-046). Canlı deney orkestratörde.

## Plan

1. Core: `EncodeBenchOptions` (argüman ayrıştırma: --fps, --seconds, --config tekrarlı) ve `EncodeBenchConfig` (saf veri + isimli katalog) + testler.
2. Host: `EncodeBench` (sentetik 420f IOSurface kareler havuzu, config başına bağımsız VT oturumları, max-hız ve --fps modu, p50/p95/p99, bit hızı, `VTCopyVideoEncoderList`). `HEVCEncoder` bu aşamada değişmez.
3. App: `EncodeBenchCommand` + main.swift'te tek satır kanca.
4. Tezgâhı tüm configlerde çalıştır, tabloyu Handoff'a yaz; 120'ye yetişen config varsa HEVCEncoder'a MATEBRIDGE_FPS=120 iken uygula.

## Handoff

- **Commit:** (aşağıda; SHA orkestratöre raporlandı)
- **Dokunulan dosyalar:** `host-mac/Sources/MateBridgeCore/Video/EncodeBench.swift` (+ `Tests/.../Video/EncodeBenchTests.swift`), `host-mac/Sources/MateBridgeHost/Video/EncodeBench.swift`, `host-mac/Sources/MateBridgeHost/Video/HEVCEncoder.swift`, `host-mac/Sources/MateBridgeApp/EncodeBenchCommand.swift`, `main.swift` (tek satır kanca), bu kart.
- **Tezgâh:** `swift build -c release && .build/release/MateBridgeApp --encode-bench [--fps N] [--seconds S] [--config NAME]...` (config yoksa katalogun tamamı). Her config için iki mod: `max` (sınırlı in-flight, olabildiğince hızlı) ve `paced 120`. 420f full-range (SCK ile aynı) 2800×1840, 12 karelik IOSurface havuzu (kayan gradyan + metin benzeri hücreler).
- **Sonuçlar** (5 s, her config ayrı süreç, release; M6 Mac mini; `enc ms` = submit→callback p50/p95/p99; in-flight 3 aksi belirtilmedikçe). Çalıştırmalar arası gürültü var (baseline 88–108 fps arası salındı; ilk turda tek süreçte art arda koşunca 72 fps'e düşme gördüm = termal/sıra artefaktı, bu yüzden ayrı süreç):

| config | max fps | paced 120 fps | enc ms p50/p95/p99 (paced) | Mbps (paced) |
|---|---|---|---|---|
| baseline (bugünkü: LLRC + RealTime) | 88–104 | 83–103 | 9.4/10.7/13.3 | 22–27 |
| realtime-off (LLRC açık) | 83–104 | 100 | 9.4/13.3/16.7 | 26 |
| power-off (MaximizePowerEfficiency=false) | 94 | 88 | 9.8/15.9/16.8 | 23 |
| no-lowlat (RealTime açık) | 103 | 100 (99 atlanan) | 8.1/42.7/49.8 | 26 |
| fps120 (ExpectedFrameRate 120) | 87–103 | 87–103 | 9.8/16/17 | 23–26 |
| main10 | 75 | 93 | 9.3/15.1/16.4 | 24 |
| br20 | 108 | 108 | 9.0/10.0/13.6 | 19 |
| br50 | 106 | 105 | 9.2/11.2/13.6 | 46 |
| dual (2 oturum) | 104 | 103 | 9.4/10.4/14.4 | 52 |
| nolat-fps120 | 117 | 106 | 6.8/33.7/36.4 | 28 |
| nolat-power-off | 117 | 107 | 6.7/33.3/35.6 | 28 |
| **nolat-rtoff** (LLRC kapalı + RealTime=false) | **174** | **119.8** | **5.8/7.3/10.2** | 31.9 |
| nolat-fps120-rtoff | 174 | 119.8 | 5.8/7.4/12.2 | 31.9 |
| combo (nolat+rtoff+power-off+fps120) | 172 | 119.8 | 5.8/7.3/11.2 | 31.9 |
| nolat-rtoff-inflight2 (uygulamadaki in-flight) | 172 | 119.6–119.9 | 5.7/7.3/11.3 | 31.9 |
| nolat-fps120-inflight1 | 114 | 94 | 6.7/11.7/14.1 | 25 |
| nolat-fps120-inflight6 | 140 | 119 | 7.0/37.9/41.1 | 31 |
| baseline-inflight1 / 6 | 108 / 108 | 108 / 108 | 9.0/10.2/13.3 | 28 |

  Kodlayıcılar: `ave.hevc` (donanım) ve `hevc.vcp` (yazılım); tek donanım kodlayıcı, ikinci oturum hız kazandırmıyor (dual ≈ tek oturum). `PrioritizeEncodingSpeedOverQuality` LLRC açıkken -12900 (desteklenmiyor) döner; LLRC kapalıyken uygulanır. br20'de 4 kare hatası (başlangıçta, hız sınırı) görüldü.
- **Bulgu:** darboğaz düşük gecikmeli hız denetimi (LLRC) yolu ~100 fps'te tavan yapıyor; **LLRC kapalı + `RealTime=false`** birlikte gerekli (tek başına biri yetmiyor): max 173 fps, 120 fps'te p50 5.8 ms / p99 ~11 ms, in-flight 2'de de geçerli. Bit hızı 120 fps'te ~32 Mbps (ayar 30).
- **Kod değişikliği:** `HEVCEncoder` artık `settings.fps >= 120` iken LLRC spec'ini vermiyor ve `RealTime=false` ayarlıyor; 60 fps yolu aynen kalıyor.
- **Varsayımlar:** tezgâh sentetik içerik kullanıyor (gerçek ekran içeriği bit hızını/hızı değiştirebilir); RealTime=false + LLRC'siz modda bit hızı kontrolü gevşek olabilir (DataRateLimits hâlâ set).
- **Test edilmeyenler / cihazda doğrulanacaklar:** `MATEBRIDGE_FPS=120` ile canlı: `enc_behind` ≈ 0 ve kodlama ~6 ms mi; keyframe-on-demand ve dropped-frame sonrası kurtarma (LLRC'siz yolda); tablet çözücüsü ~120 fps'i kaldırıyor mu (üretici ölçümü 105–115); ağ bit hızı dalgalanması (burst); 60 fps yolunun değişmediği. Yalnız tezgâh koşturuldu; uygulama/SCK/ağ çalıştırılmadı.
- **Açık sorular:** RealTime=false çıktı gecikmesi canlıda (yakalamadan tablete) ölçülmeli.
