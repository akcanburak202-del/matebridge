---
id: T-089
title: Tablet — Wi-Fi ölçüm altyapısı ve düğmeler (RTT istatistiği, aktarım logu, trafik sınıfı, WifiLock düşük gecikme)
status: in-progress
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

1. **Saf mantık (`session/WifiKnobs.kt`, yeni):** `WifiKnobs` (ping_ms varsayılan 500, [20, 1000] aralığına sıkıştırılır; `tos_ctl`/`tos_video` yalnız 0..255 ise geçerli, yoksa null; `wifi_ll` varsayılan false) — `parse(has, getInt, getBool)` ile Android'siz test edilir; `logFields()`. `RttStats` (iş parçacığı güvenli pencere: `add(rttUs)`, `snapshot(reset)` → n, p50, p95, max; `format()` → `rtt_ms_p50_95_max=a/b/c rtt_n=N`, boşsa `-`). `TrafficClass.apply(requested, set, get)` → log alanları (istek yoksa hiçbir şey yapmaz; hata oturumu öldürmez). `WifiLockPolicy.shouldHold(enabled, transport, started, ui)` (Wi-Fi + açık + aktivite başlatılmış + yalnız `SessionUi.Connected`; uygularken daraltıldı) ve `WifiLockHolder` (sahte arka uçla test edilen idempotent acquire/release, her değişimde `wifi_lock held=…` logu).
2. **SessionMachine:** kurucuya `pingIntervalUs` (varsayılan `PING_INTERVAL_US` = 500 ms); PONG zaman aşımı aynı (3 s).
3. **SessionController:** `WifiKnobs` parametresi; motor tik'i `min(100, ping_ms)` (ping çözünürlüğü için, varsayılanda değişmez); kontrol ve video soketlerine `connect` öncesi `setTrafficClass`, bağlantı sonrası `getTrafficClass()` logu (`ev=traffic_class sock=control|video requested=… applied=…`). `session_start` logu: `transport=usb|wifi ping_ms=… tos_ctl=… tos_video=… wifi_ll=…`.
4. **MainActivity:** ekleri ayrıştır; `onPong`'da RTT örneği `RttStats`'a; oturum başında sıfırla. Saniyelik istatistik tikinde ayrı `MB/session ev=net transport=… rtt_ms_p50_95_max=… rtt_n=… ping_ms=…` satırı. WifiLock: `render()` (her UI durumu), `onStop`, `onDestroy`'da politika ile senkron; arka plan/bağlantı kopması/oturum sonu → bırakılır.
5. **Manifest:** `WAKE_LOCK` izni.
6. Testler: `WifiKnobsTest` (ayrıştırma, RTT penceresi, trafik sınıfı, kilit politikası/tutucu), `SessionMachineTest`'e ping aralığı testi. `./scripts/check.sh`.

## Handoff

