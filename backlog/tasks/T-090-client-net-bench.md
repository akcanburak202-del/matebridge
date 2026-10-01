---
id: T-090
title: Tablet — ham ağ hızı ölçüm kipi (`--es net_bench host:port`), Wi-Fi kapasitesini uygulamadan bağımsız ölçmek için
status: todo
phase: 5
owner: android-client-dev
depends_on: [T-089]
decisions: []
files:
  - client-android/app/src/main/
  - client-android/app/src/test/
  - backlog/tasks/T-090-client-net-bench.md
---

## Amaç

Wi-Fi ölçümü (orkestratör, 2026-10-01 ~17:45):
- Akıcı modda Wi-Fi akışı ~27 Mbps'te doyuyor: 8–11 fps, gecikme 350–390 ms, host gönderim kuyruğu 300 KB–1,1 MB, RTT yük altında ~28 ms (boşta 5–22 ms).
- `wifi_ll`, `tos` ve `SERVICE_CLASS` fark yaratmadı.
- Tablette `nc`, `curl` ve `wget` yok; ham TCP kapasitesi ölçülemiyor.

Mac tarafında basit bir Python gönderici/alıcı çalışacak (orkestratör scratch). Tablet tarafına bir deney kipi gerekiyor.

## Kabul kriterleri

- [ ] `am start -n dev.matebridge.client/.MainActivity --es net_bench HOST:PORT [--ei net_bench_s 8] [--es net_bench_dir down|up|both] [--ei net_bench_streams 1]`:
  - Normal oturum **başlatılmaz**.
  - Arka plan iş parçacığında HOST:PORT'a TCP bağlanır.
  - `down`: gelen baytları süre boyunca okuyup atar. `up`: 64 KB tamponları süre boyunca yazar. `both`: iki ayrı bağlantı açar.
  - `net_bench_streams` N paralel bağlantı açar (1–4).
  - Her saniye log yazar: `MB/netbench ev=tick dir=… mbps=… bytes=…`. Sonunda özet: `ev=done dir=… mbps_avg=… mbps_min=… mbps_max=…`.
  - Okuma tamponu 256 KB. `SO_RCVBUF` ayarlanmaz (varsayılan otomatik ayar korunur); isteğe bağlı `--ei net_bench_rcvbuf_kb N`.
- [ ] Ekranda basit bir metin: "Ağ ölçümü… X Mbps". Bitince kendiliğinden kapanmaz, sonuç ekranda kalır.
- [ ] Kip yalnızca bu ek parametreyle çalışır. Normal açılış davranışı değişmez. Kimlik doğrulama ya da şifreleme yoktur (ham soket; yalnızca deney). Uygulama bu kipte hiçbir girdi göndermez.
- [ ] Saf mantık (parametre ayrıştırma, Mbps hesabı) testli.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

(ajan doldurur, commit eder, sonra uygular)

## Handoff

