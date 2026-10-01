---
id: T-072
title: Mac — gecikme ölçümünün başlangıç noktası (yakalama zamanı) ve 120 fps'te kodlayıcı öncesi bekleme
status: done
phase: 5
owner: mac-host-dev
depends_on: [T-070]
decisions: []
files:
  - host-mac/Sources/MateBridgeCore/Video/
  - host-mac/Sources/MateBridgeHost/Video/
  - host-mac/Sources/MateBridgeHost/Session/
  - host-mac/Tests/
  - backlog/tasks/T-072-host-latency-metric-and-hold.md
---

## Amaç

Kullanıcı: "ekran aktarımını mümkün olduğunca mükemmelleştirelim". İki host konusu (T-070 kartının sonundaki notlar):

1. **Ölçüm başlangıcı yanlış:** cihazda (11c0add) `sck_lag` hep `0.0`, `cap_to_sent` p50 4,0 ms < `enc` 7,0 ms. `SCStreamFrameInfo.displayTime` (mach tik) dönüşümü ya da kırpma şüpheli (Apple Silicon'da tik ≠ ns, `mach_timebase_info` 125/3). Ayrıca tellerdeki `capture_time_us` (PTS) ile `displayTime` ilişkisini ölç: tablet gecikme ve pacing'i `capture_time_us`'e dayandırıyor; PTS gerçek ekran zamanından sapıyorsa bunu bilmek istiyoruz.
2. **Kodlayıcı öncesi bekleme:** 120 fps'te seyreltme yokken `hold` p50 bazı pencerelerde 1,1–2,3 ms (en çok ~2,9). T-070b'nin açıklaması: (a) `FramePacer.offer` kapıyı varış zamanına göre denetliyor, tolerans 2 ms / 8,33 ms ızgara → 2 ms'den erken gelen kare zamanlayıcıyla bekletiliyor; (b) `maxInFlight=2`, kodlama 6–7,5 ms → iki yuva dolu olunca bekleme.

## Kabul kriterleri

- [ ] **Ölçüm:** `capture` başlangıcı doğru saat tabanında; cihazda `sck_lag` > 0 olmalı (değilse nedenini kanıtla). `cap_to_sent` ≥ `enc` (test: aşamaların toplamı). `ev=latency` satırına `pts_vs_display` farkı (p50/p99) eklenebilir.
- [ ] **Bekleme ayrıştırması:** `hold` ikiye ayrılır: `gate_wait` (kapı) ve `slot_wait` (yuva dolu). Log alanları karta yazılır.
- [ ] **Bekleme azaltma (seyreltme yokken):** kapının amacı ortalama hızı akış fps'inin altında tutmak; SCK zaten sanal ekranın yenileme hızında (= akış fps) teslim ediyor. Seyreltme yokken erken gelen kare, yarım kaynak aralığına kadar (120 fps'te ~4,17 ms) bekletilmeden gönderilir; uzun vadeli ortalama hız sınırı korunur (art arda patlama kaynaklı ikiden fazla kare hızlı geçmez). Gerekçeyi ve testleri yaz: (1) 120 Hz düzgün akışta (±1,5 ms titreşim, sabit faz kayması) `gate_wait` ≈ 0; (2) SCK patlaması (aynı anda 3 kare) ortalamayı aşmaz; (3) seyreltme (T-058/T-066) davranışı değişmez.
- [ ] Yuva beklemesi (`maxInFlight=2`): ölç, değiştirme; neden dolu kaldığını (VT çıkış gecikmesi?) karta yaz, öneri *Açık sorular*a.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

1. displayTime dönüşümü probe ile doğrulandı (125/3, CM host saatiyle aynı taban) -> dönüşüm hata değil; SCK damgaları geri çağrıdan ÖNCE değil SONRA çıkıyor. İz başlangıcı = min(display, pts, delivered); ham damgalar işaretli ofsetlerle loglanır.
2. hold = gate_wait + slot_wait (kare yuva doluyken geldiyse son yuva boşalmasına kadar slot_wait).
3. Seyreltme yokken kapı toleransı = yarım kaynak aralığı; seyreltmede değişmez. Testler FrameGateTests/LatencyTraceTests.

## Handoff

- **Commit:** bkz. `git log task/T-072-host-metric-hold` (SHA raporda)
- **Dokunulan dosyalar:** MateBridgeCore/Video/{LatencyTrace,FrameGate}.swift; MateBridgeHost/Video/{HEVCEncoder,ScreenCapture}.swift; Tests/.../Video/{FrameGateTests,LatencyTraceTests}.swift
- **Bulgu (ölçüm):** `mach_timebase_info` bu Mac'te 125/3; `ticks*125/3` ns ve `CMClockGetHostTimeClock` aynı taban (probe: fark = okuma aralığı). Dönüşüm doğru, kırpma da neden değil. Cihazdaki `sck_lag=0` ve `cap_to_sent < enc` ancak hem `displayTime` hem PTS geri çağrı anından SONRA (ileride) ise açıklanır. Doğrulama cihazda: yeni `*_vs_deliv` alanları.
- **Düzeltme:** iz başlangıcı `FrameTrace.origin` = min(displayTime, PTS, delivered); `cap_to_sent` aşamaların toplamından asla kısa değil; `sck_lag` > 0 yalnızca damgalar gerçekten geriden geliyorsa. Tel `capture_time_us` değişmedi (PTS).
- **Yeni log alanları** (`ev=latency`): `gate_wait_ms_p50_95_99_max`, `slot_wait_ms_p50_95_99_max` (hold = gate + slot; sıra: sck_lag, hold, gate_wait, slot_wait, enc, conv, queue, write, cap_to_sent); işaretli `pts_vs_display_ms_p50_99`, `pts_vs_deliv_ms_p50_99`, `display_vs_deliv_ms_p50_99` (ilk damga - ikinci; pts_vs_deliv > 0 = PTS geri çağrıdan ileride); `no_display=N`. CSV değişmedi.
- **Bekleme ayrıştırması:** `slot_wait` = kare iki yuva doluyken geldiyse varıştan son yuva boşalmasına kadar; kalan `gate_wait`.
- **Kapı değişikliği ve gerekçe:** seyreltme yokken `FrameGate` toleransı 2 ms -> yarım kaynak aralığı (120 fps 4,17 ms; 60 fps 8,33 ms). Kapı yalnız ortalama hızı sınırlar; SCK zaten akış fps'inde teslim eder; 2 ms, ±1-2 ms jitter + faz kaymasını karşılamıyordu, kare zamanlayıcıyla bekliyordu. Izgara hâlâ kabul başına tam bir aralık ilerler: uzun vadeli hız <= fps; 3'lü patlamada en çok 2 kare geçer (biri hemen, biri en erken yarım aralık sonra, en yeni kazanır). Seyreltmede tolerans min(2 ms, aralık/4) aynen (testle sabit). Testler: 120 Hz jitter + 3 faz -> held=0; 60 Hz jitter; 3'lü patlama; 240 Hz kaynak <= 120 fps; tolerans tablosu; mach dönüşümü; origin; işaretli ofsetler; hold ayrışması.
- **Yuva beklemesi (`maxInFlight=2`):** değiştirilmedi, yalnız ölçülür (`slot_wait`). Neden dolu: kodlama 6-7,5 ms > 120 fps aralığının (8,33 ms) yarısı; iki kare uçuştayken üçüncüsü bekler. Karar cihaz verisinden sonra.
- **Varsayımlar:** `displayTime` `UInt64` mach ticks olarak okunabiliyor (olmazsa `no_display` sayar). Damgaların geri çağrıdan ileride olması hipotez; log kanıtlayacak.
- **Test edilmeyenler / cihazda doğrulanacaklar:** yeni alanlar gerçek akışta, `pts_vs_deliv` işareti, 120 fps'te `gate_wait` p50 ~ 0, seyreltmesiz akışta kare hızı/sıçrama artmadı (tolerans büyüdü: kareler yarım aralık erken gidebilir). Host çalıştırılmadı.
- **Açık sorular:** damgalar geri çağrının ilerisindeyse tabletin `capture_time_us` (PTS) tabanlı gecikmesi host gecikmesini PTS - delivered kadar az gösterir. Öneri: tablet ölçümüne bu ofseti ekle ya da telde geri çağrı zamanını kullan (protokol kararı, orkestratör).
