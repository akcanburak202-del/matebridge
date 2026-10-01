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

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
