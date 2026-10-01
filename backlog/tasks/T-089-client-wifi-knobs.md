---
id: T-089
title: Tablet — Wi-Fi ölçüm altyapısı ve düğmeler (RTT istatistiği, aktarım logu, trafik sınıfı, WifiLock düşük gecikme)
status: todo
phase: 5
owner: android-client-dev
depends_on: [T-077]
decisions: []
files:
  - client-android/app/src/main/
  - client-android/app/src/test/
  - backlog/tasks/T-089-client-wifi-knobs.md
---

## Amaç

Wi-Fi modu çalışması (orkestratör araştırması, 2026-10-01 ~17:40):
- İstemci yalnızca `bestRttUs`'yi logluyor (`MainActivity.kt` ~979). Ping her 500 ms (`SessionMachine.kt` ~313).
- Soketlerde trafik sınıfı (DSCP/WMM) yok. Wi-Fi'de kalem örnekleri öbekleniyor (p95 ~10 ms, NOTES 2026-09-30); olası neden, kalem yukarı yönünün AP'nin büyük video patlamalarıyla yayın süresi için yarışması.
- WifiLock yok. T-019'daki wifilock yarısı park edildi.

Varsayılan davranış değişmez; düğmeler `am start` ek parametreleriyle açılır (mevcut `--ez/--ei` deneme düğmesi kalıbı).

## Kabul kriterleri

- [ ] `session_start` logunda `transport=usb|wifi`.
- [ ] Saniyelik (ya da mevcut istatistik penceresindeki) `MB/session` satırına RTT `rtt_ms_p50_95_max` eklenir. Ping aralığı düğmesi `--ei ping_ms N` (varsayılan bugünkü 500).
- [ ] `--ei tos_ctl N` ve `--ei tos_video N` (varsayılan yok): kontrol ve video soketlerine `Socket.setTrafficClass(N)`. Önerilen değerler: kontrol 0xB8 (EF → AC_VO), video 0x88 (AF41 → AC_VI). Uygulanan değer `getTrafficClass()` ile log'a yazılır.
- [ ] `--ez wifi_ll true` (varsayılan false): Wi-Fi aktarımında oturum süresince `WifiManager.createWifiLock(WIFI_MODE_FULL_LOW_LATENCY, …)`. Arka plana geçince, oturum bitince ve bağlantı kopunca mutlaka bırakılır. `WAKE_LOCK` izni manifest'e eklenir. Log: `wifi_lock held=…`.
- [ ] Mevcut kalem/girdi akışı değişmez (girdi takılı kalmaz; yalnızca soket seçeneği eklenir).
- [ ] Saf mantık (RTT istatistik penceresi, düğme ayrıştırma) birim testli.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

(ajan doldurur, commit eder, sonra uygular)

## Handoff

