---
id: T-070
title: Mac — yakalama→gönderim gecikme dökümü (SCK teslim, kodlama, kuyruk, soket yazımı) ve sıçrama kaynağı
status: todo
phase: 5
owner: mac-host-dev
depends_on: [T-066]
decisions: []
files:
  - host-mac/Sources/MateBridgeCore/Video/
  - host-mac/Sources/MateBridgeHost/Video/
  - host-mac/Sources/MateBridgeHost/Session/
  - host-mac/Tests/
  - backlog/tasks/T-070-host-latency-breakdown.md
---

## Amaç

NOTES 2026-10-01 ~11:30: 60 Hz'te akıcılık ↔ gecikme ödünleşimi girdi sapmasından geliyor. Tablet ölçümü: yakalama zaman damgası → tablete varış p50 **16,6 ms** (bunun ~6,8 ms'si kodlama), p95 ~18 ms, bazı saniyelerde p99 **40–44 ms**. USB modunda (adb reverse tüneli). Kodlama dışındaki ~10 ms'nin ve sıçramaların nerede oluştuğunu bilmiyoruz. Bu kart **ölçüm** ekler, davranış değiştirmez.

## Kabul kriterleri

- [ ] Kare başına host zamanları (aynı saat, µs): `capture` (SCK zaman damgası), `delivered` (SCK geri çağrısı), `submitted` (kodlayıcıya verildi; tutma/seyreltme beklemesi dahil), `encoded` (kodlayıcı çıktı geri çağrısı), `enqueued` (gönderim kuyruğu), `write_start`, `write_done` (soket yazımı tamamlandı / `send` tamamlanma geri çağrısı).
- [ ] `ev=cadence` satırına (ya da ayrı `ev=latency` satırına, saniyede bir) her aşama farkının p50/p95/p99'u ve en büyük değeri: `sck_lag`, `hold`, `enc`, `queue`, `write` ve toplam `cap_to_sent`. Alan adlarını karta yaz; `docs/LOGGING.md`'ye dokunma.
- [ ] İsteğe bağlı: `MATEBRIDGE_LAT_TRACE=1` ortam değişkeniyle kare başına satırları `~/Library/Logs/MateBridge/latency.csv`'ye (sınırlı boyut) yaz.
- [ ] Ek yük ihmal edilebilir (kilitsiz/az kilitli sayaçlar; kare başına tahsis yok).
- [ ] Testler (yüzdelik hesap, alan biçimi). `./scripts/check.sh` geçiyor.

## Plan

Her kare, `EncodedVideoFrame.trace` (`FrameTrace`, 7 x UInt64, tahsissiz) ile aşama damgalarını taşır: SCK geri çağrısı (`encode()` girişi) -> `send()` (VT'ye verildi) -> VT geri çağrısı -> `VideoPipeline` kuyruğa iterken `enqueued` -> `VideoSender` yazma başlangıcı / `contentProcessed` tamamlanması. Sender tamamlanmış izi `LatencyMeter`'a (kilitli, saniyelik pencere) verir; `StreamCoordinator.reportCadence` saniyede bir `ev=latency` satırı yazar. `MATEBRIDGE_LAT_TRACE=1` ile `RotatingLogFile` üzerinden sınırlı (8 MiB x 2) `latency.csv`. Davranış değişmez.

## Handoff

- **Commit:** bkz. `git log task/T-070-host-latency-breakdown` (SHA raporda)
- **Log alanları** (`component=video ev=latency`, saniyede bir, yalnızca kare gönderildiyse): `frames=N` ve her aşama için `<aşama>_ms_p50_95_99_max=p50/p95/p99/max` (ms, 1 ondalık). Aşamalar: `sck_lag` (SCK zaman damgası -> SCK geri çağrısı), `hold` (geri çağrı -> kodlayıcıya verildi; seyreltme/tutma/slot bekleme), `enc` (verildi -> VT çıktı geri çağrısı), `conv` (VT çıktısı -> gönderim kuyruğu; Annex-B dönüşümü), `queue` (kuyruk -> sender yazmayı başlattı; soket slotu beklemesi dahil), `write` (yazma başlangıcı -> `contentProcessed`; mühürleme + soket), `cap_to_sent` (SCK zaman damgası -> yazma tamamlandı). Pencere başına en çok 512 örnek. CSV (`~/Library/Logs/MateBridge/latency.csv`, `MATEBRIDGE_LAT_TRACE=1`): `capture_us,delivered_us,submitted_us,encoded_us,enqueued_us,write_start_us,write_done_us` (host saati µs, kare başına bir satır).
- **Dokunulan dosyalar:** MateBridgeCore/Video/{LatencyTrace (yeni),EncodedVideoFrame,VideoSender}.swift; MateBridgeHost/Video/{HEVCEncoder,VideoPipeline,LatencyCsv (yeni)}.swift; MateBridgeHost/Session/StreamCoordinator.swift; Tests/MateBridgeCoreTests/Video/{LatencyTraceTests (yeni),IntegrationTests}.swift
- **Varsayımlar:** SCK zaman damgası ve `HostClock` aynı saat (PROTOCOL 6 zaten bunu varsayar). `delivered` = `HEVCEncoder.encode()` girişi (SCK handler'ından hemen sonra). Tutma-zamanlayıcısıyla yeniden gönderilen karelerde `capture=delivered=now`. `write_done` = NWConnection `contentProcessed` (USB/adb reverse'te tünele devir; tabletin aldığı an değil). Codec config kareleri ölçülmez; anahtar kareler ölçülür. Geriye giden aşama 0'a kırpılır.
- **Test edilmeyenler / cihazda doğrulanacaklar:** Gerçek akışta `ev=latency` satırının çıkması ve değerlerin tablet ölçümüyle uyumu; CSV'nin oluşması. Ek yük (kare başına ~4 HostClock okuması) ölçülmedi. Host çalıştırılmadı.
- **Açık sorular:** yok

## Orkestratör notu (2026-10-01 11:42, cihaz)

`ev=latency` satırı geliyor, ama: (1) `sck_lag` her zaman `0.0/0.0/0.0/0.0` → `capture` zamanı SCK zaman damgası değil, geri çağrı anı alınıyor; (2) `cap_to_sent` p50 0,7–2,3 ms, yani `enc` (6–7,5 ms) dan bile kısa → toplam yanlış bir başlangıç noktasından ölçülüyor. Gözlemler: `hold` p50 bazı pencerelerde 1,1–2,3 ms (120 fps, seyreltme yok — kapı ızgarası erken gelen kareleri bekletiyor olabilir), `queue`+`write` ~0,2 ms, en büyük değerlerde sıçrama yok.

### Düzeltme kabul kriterleri

- [ ] `capture` = SCK karesinin gerçek zaman damgası (`CMSampleBuffer` sunum zamanı / `SCStreamFrameInfo.displayTime`, host saatine çevrilmiş) — tabletin kullandığı `capture_time_us` ile aynı kaynak. `sck_lag` gerçek teslim gecikmesini göstermeli.
- [ ] `cap_to_sent` = `write_done - capture`; testte aşamaların toplamına eşit olduğu doğrulanır.
- [ ] `hold` 120 fps'te seyreltme yokken neden > 0: kısa açıklama karta (kapı toleransı / ızgara fazı); davranış değişikliği önerisi varsa *Açık sorular*a.

### Düzeltme (T-070b) — Handoff

- **Neden 0 / kısa toplam:** `capture` olarak `CMSampleBufferGetPresentationTimeStamp` alınıyordu; bu değer geri çağrı anından sonra (ya da eşit) çıkıyor, `sck_lag` 0'a kırpılıyordu ve `cap_to_sent` (= write_done - capture) gerçekten daha kısa görünüyordu. Düzeltme: iz başlangıcı artık `SCStreamFrameInfo.displayTime` (mach ticks -> µs, `ScreenCapture.machTicksToUs`; yoksa PTS'e geri döner). Kırpma yok: displayTime geri çağrıdan sonraysa `sck_lag` yine 0 görünür ve bu başlı başına bulgudur. **Tel üzerindeki `capture_time_us` değişmedi** (hâlâ PTS; protokol/ızgara davranışı aynı). Gerçek yayında `sck_lag` > 0 çıkıp çıkmadığı cihazda doğrulanmalı; hâlâ 0 ise displayTime da geleceği gösteriyor demektir ve tablet ölçümünün başlangıcı da şüpheli olur (orkestratöre açık soru).
- **`cap_to_sent`:** `write_done - capture`; `testCapToSentIsSumOfStages` aşamaların toplamına eşitliği doğrular (monoton damgalarla).
- **`hold` > 0 neden (120 fps, seyreltme yok):** `FramePacer.offer` seyreltmeyen yolda kapıyı varış zamanıyla (`gate.waitUs(nowUs:)`) sorar. Izgara her kabul edilen karede bir aralık (8,33 ms) ilerler, tolerans yalnızca 2 ms. SCK teslim jitter'ı 2 ms'yi aşan bir kare, slotundan erken geldiği için tutulur ve `retryAfter` zamanlayıcısıyla (en çok ~6 ms'ye kadar) gönderilir; ayrıca ızgara fazı bir kare geç kalmış bir kareden sonra kalan kareyi kaydırır. İkinci neden: `maxInFlight=2` slotu dolu iken kare tek bekleyen kareye yazılır ve slot boşalınca gider (hold'a slot bekleme de dahil). Kodlama 6-7,5 ms > 8,33/2 olduğundan 120 fps'te iki slot sık dolar.
- **Öneri (davranış değişmedi):** seyreltme yokken kapıyı devre dışı bırakmak ya da toleransı kaynak aralığının ~yarısına (4 ms) çıkarmak `hold`u azaltır; bu T-071 ile ilgili (varsayılan 6 ms son tarih) ve orkestratör kararı.
- **Dokunulan:** Video/{ScreenCapture,HEVCEncoder,VideoPipeline}.swift (Host), Tests/.../LatencyTraceTests.swift. Cihazda çalıştırılmadı.
