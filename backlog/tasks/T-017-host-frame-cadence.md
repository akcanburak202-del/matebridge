---
id: T-017
title: Mac kare temposu — yakalama aralığı ölçümü, sanal ekran yenileme hızı, kayıp karelerin kaynağı
status: done
phase: 1
owner: mac-host-dev
depends_on: [T-014]
decisions: [0002]
files:
  - host-mac/Sources/MateBridgeHost/Video/
  - host-mac/Sources/MateBridgeHost/VirtualDisplay.swift
  - host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift
  - host-mac/Sources/MateBridgeCore/Video/
  - host-mac/Sources/MateBridgeApp/DumpVideoCommand.swift
  - host-mac/Tests/MateBridgeCoreTests/Video/
---

## Amaç

Tablette 60 fps içerik ~57 fps geliyor (NOTES 2026-09-29, T-016 ölçümleri). Test sayfasının kendisi de Mac'te 56–57 fps gösteriyor: kareler Mac tarafında, gönderilmeden önce kayboluyor. Hedef: nerede kaybolduğunu ölçmek ve 60 fps içeriğin 60 fps'e yakın ve düzenli çıkmasını sağlamak.

## Kabul kriterleri

- [x] **Ölçüm:** host saniyede bir `component=video ev=cadence` logu yazar: SCK kare varış aralığı p50/p95/p99 ve >1,5×hedef aralık sayısı, SCK'nın bildirdiği kare durumları (complete/idle/blank/suspended…) sayıları, kodlayıcıya giren/çıkan kare sayısı, kodlama süresi p50/p95, `pending` slot üzerine yazılan (en yeni kazanır) kare sayısı, kuyruk atmaları, gönderilen kare sayısı. Saf istatistik kısmı Core'da ve testli. Menüdeki özet satırına "cap fps / enc fps / sent fps" eklenir.
- [x] **Sanal ekran yenileme hızı:** `VirtualDisplay` modu 60 ve 120 Hz ile oluşturulabilir (ayar/ortam değişkeni/komut satırı, varsayılan 60). 120 Hz sanal ekranda SCK `minimumFrameInterval` 1/60 olarak kalır (tablete giden en fazla 60 fps). Seçilen mod ve gerçekten uygulanan yenileme hızı loglanır.
- [x] `--dump-video` aynı ölçüm özetini yazdırır ve `--refresh 60|120` alır; orkestratör Safari 60 fps animasyon sayfasıyla iki modu karşılaştırır.
- [x] Kodlayıcı ayarları gözden geçirilir: `ExpectedFrameRate`, `MaxFrameDelayCount` (0/1), gerekirse `RealTime`; her birinin uygulanıp uygulanmadığı loglanır.
- [x] `./scripts/check.sh` geçiyor.

## Notlar

- Ölçüm önce: kaybı açıklayan veri olmadan ayar değiştirme. Bulguları Handoff'a yaz.
- Tablet tarafı (T-016): HarmonyOS video yüzeyinde 60 Hz'e kilitli; tablet tarafında kare temposu için şu an yapılacak iş yok.

## Plan

1. Core (saf, testli): `CadenceWindow`/`CadenceMeter` (SCK aralık p50/p95/p99, geç aralık sayısı, durum sayaçları, enc in/out, overwritten, kuyruk atma, gönderilen; log ve menü metni), `VideoSettings.displayRefreshHz` + `maxFrameDelayCount` ve ayrıştırıcıları.
2. Host: `ScreenCapture` durum adı + varış saatini meter'a yazar; `HEVCEncoder` in/out/overwritten sayar, uygulanan özellikleri raporlar ve okur; `VirtualDisplay` istenen Hz'e en yakın modu seçer ve gerçek modu bildirir; `VideoPipeline` pencereyi kapatır.
3. Koordinatör: saniyede bir `component=video ev=cadence` logu + menüye "cap/enc/sent fps", `cadence_setup` logu. Ortam değişkenleri `MATEBRIDGE_REFRESH=60|120`, `MATEBRIDGE_FRAME_DELAY=0|1`.
4. `--dump-video`: `--refresh`, `--frame-delay`, saniyelik `cadence` satırı + TOTAL.

## Handoff

- **Commit:** bkz. `git log task/T-017-frame-cadence`
- **Dokunulan dosyalar:** Core: `Video/CadenceMeter.swift` (yeni), `Video/VideoSettings.swift`; Host: `Video/{HEVCEncoder,ScreenCapture,VideoPipeline,VideoDump}.swift`, `VirtualDisplay.swift`, `Session/StreamCoordinator.swift`; Tests: `Video/CadenceTests.swift`; bu kart. `main.swift` ve `DumpVideoCommand.swift` değişmedi (menü satırı mevcut `onSummary` üzerinden).
- **Ne ölçülüyor (saniyede bir, `component=video ev=cadence`):** `cap_int_ms_p50_95_99` SCK'nın kendi PTS'i ile ardışık `complete` kareler arası; `arr_int_ms_*` aynısı ama örnek işleyicisinin çağrılma saatiyle (teslim titreşimi); `cap_late/arr_late` >1,5x hedef aralık; `status=` SCK durumları (complete/idle/blank/suspended/started/stopped); `enc_in/enc_out`, `enc_ms_p50_95`, `overwritten` (tek `pending` slotunda ezilen), `queue_drops`, `sent`. Kayıp hattı: cap > enc_in ise yakalamada; enc_in > enc_out ise `overwritten`/kodlayıcı; enc_out > sent ise `queue_drops`. Menü: "58 fps · 30.0 Mbit/s · 35 ms · cap 60 / enc 60 / sent 60 fps".
- **`cadence_setup` logu (display_created sonrası) ve dump'ta `cadence setup:`:** sanal ekranın istenen Hz'i, mod seçildi mi, sistemin bildirdiği gerçek mod (`applied=... 120Hz`; sistem 0 Hz bildirirse 0 görünür); kodlayıcıya set edilen her özellik `Ad=ok|OSStatus`, oturumun geri okuduğu `RealTime/ExpectedFrameRate/MaxFrameDelayCount/Hardware`; SCK `minimumFrameInterval` ve `queueDepth`.
- **Ayarlar:** `--dump-video ... --refresh 60|120 [--frame-delay 0|1]`; uygulamada `MATEBRIDGE_REFRESH=60|120` ve `MATEBRIDGE_FRAME_DELAY=0|1` ortam değişkenleri (Terminal'den başlatılan ikili için). Varsayılan 60 Hz, `MaxFrameDelayCount` ayarlanmaz (ölçüm önce). 120 Hz'de akış fps'i ve SCK `minimumFrameInterval` 1/60 kalır (`displayRefreshHz` STREAM_CONFIG'e girmez).
- **Varsayımlar:** `ExpectedFrameRate` ve `RealTime` zaten set ediliyordu (artık loglanıyor). Mod seçimi "en yüksek Hz" yerine "istenene en yakın Hz". Durağan ekranda SCK kare vermediği için ölçüm boş, log satırı atlanır.
- **Test edilmeyenler / cihazda doğrulanacaklar:** Yalnızca derleme + Core birim testleri (`CadenceTests`), uygulama çalıştırılmadı. Orkestratör: Safari 60 fps sayfası ile `--dump-video x.h265 --seconds 10 --refresh 60` ve `--refresh 120`; TOTAL satırında `cap_fps`, `cap_late`, `status=`, `overwritten` karşılaştırın. Şüphe (ölçülmedi): SCK `minimumFrameInterval`=1/60 iken 60 Hz ekranda kareler aralığın hemen altında gelirse SCK bazılarını eler (cap_fps ~57); 120 Hz sanal ekranda düzelmeli. macOS sanal ekranda 120 Hz'i kabul etmezse `applied=` 60 gösterir. `MaxFrameDelayCount` etkisi `--frame-delay 0|1` ile denenebilir.
- **Orkestratör cihaz sonuçları ve kök neden (Safari 60 fps sayfası, Safari sekme başlığında sabit 60 fps):**

  | run | cap_fps | cap_int p50/p95/p99 | notes |
  |---|---|---|---|
  | refresh 60, SCK min 16.67 ms | 57.4 | 16.7/16.7/33.3 | all frames complete, enc/sent same, no overwrites |
  | refresh 120, SCK min 16.67 ms | 57.8 | 16.7/25.0/33.3 | worse regularity |
  | refresh 60, SCK min 8.33 ms (--fps 120) | 60.0 | 16.7/16.7/16.7 | enc 59.9, sent 60.0 |

  Kök neden: `minimumFrameInterval` tam 1/fps iken SCK biraz erken gelen kareleri eler. **`--refresh 120` yardımcı olmadı** (57.8 fps, düzensizlik daha kötü); seçenek olarak duruyor, varsayılan 60.
- **Düzeltme (2. tur):** (1) SCK `minimumFrameInterval` = 1/(2 x akış fps); sanal ekran 60 Hz, STREAM_CONFIG fps değişmedi. (2) Core `FrameGate` + `HEVCEncoder`: iki kabul edilen kare arası en az 0,75 x akış aralığı; daha erken gelen kare atılmaz, tek `pending` slotuna yazılır (en yeni kazanır, `overwritten` sayılır) ve aralık dolunca zamanlayıcıyla gönderilir, böylece gönderim ~akış fps'ini geçmez ve durağan ekranda son kare bayat kalmaz. Anahtar kare yeniden gönderimleri kapıyı atlar. 0,75 seçimi: 1'e yakın sabit titreşimde kareleri geciktirir, 0,5 ise 120 fps patlamayı 60'a indirmez; sürekli üst sınır ~66 fps. Testler `FrameGateTests`. (3) `late` zaten akış aralığına göre (`CadenceMeter(fps: settings.fps)`); 547 yanlış `late`, `--fps 120` ile akış fps'i 120 yapılıp hedefin 8,33 ms olmasındandı, SCK minimumundan değil. Şimdi SCK minimumu akış fps'inden bağımsız.
- **Açık sorular:** Yok. Kart `files:` dışına çıkılmadı.

## Orkestratör cihaz testi (2026-09-29)

Varsayılan ayarla `--dump-video` + Safari 60 fps: cap 60,0 fps, p50/95/99 16,7/16,7/16,7, late 0, overwritten 0, sent 60,0. Canlı: tablete ~60 fps, gecikme Wi-Fi 26–33 ms, USB ~19 ms. Codex incelemesi ayrıca işlenecek.

