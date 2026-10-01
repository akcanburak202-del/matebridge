---
id: T-072
title: Mac — gecikme ölçümünün başlangıç noktası (yakalama zamanı) ve 120 fps'te kodlayıcı öncesi bekleme
status: todo
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

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
