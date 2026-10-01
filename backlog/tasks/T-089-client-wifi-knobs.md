---
id: T-089
title: Tablet — Wi-Fi ölçüm altyapısı ve düğmeler (RTT istatistiği, aktarım logu, trafik sınıfı, WifiLock düşük gecikme)
status: review
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

- [x] `session_start` logunda `transport=usb|wifi`.
- [x] Saniyelik (ya da mevcut istatistik penceresindeki) `MB/session` satırına RTT `rtt_ms_p50_95_max` eklenir. Ping aralığı düğmesi `--ei ping_ms N` (varsayılan bugünkü 500).
- [x] `--ei tos_ctl N` ve `--ei tos_video N` (varsayılan yok): kontrol ve video soketlerine `Socket.setTrafficClass(N)`. Önerilen değerler: kontrol 0xB8 (EF → AC_VO), video 0x88 (AF41 → AC_VI). Uygulanan değer `getTrafficClass()` ile log'a yazılır.
- [x] `--ez wifi_ll true` (varsayılan false): Wi-Fi aktarımında oturum süresince `WifiManager.createWifiLock(WIFI_MODE_FULL_LOW_LATENCY, …)`. Arka plana geçince, oturum bitince ve bağlantı kopunca mutlaka bırakılır. `WAKE_LOCK` izni manifest'e eklenir. Log: `wifi_lock held=…`.
- [x] Mevcut kalem/girdi akışı değişmez (girdi takılı kalmaz; yalnızca soket seçeneği eklenir).
- [x] Saf mantık (RTT istatistik penceresi, düğme ayrıştırma) birim testli.
- [x] `./scripts/check.sh` geçiyor.

## Plan

1. **Saf mantık (`session/WifiKnobs.kt`, yeni):** `WifiKnobs` (ping_ms varsayılan 500, [20, 1000] aralığına sıkıştırılır; `tos_ctl`/`tos_video` yalnız 0..255 ise geçerli, yoksa null; `wifi_ll` varsayılan false) — `parse(has, getInt, getBool)` ile Android'siz test edilir; `logFields()`. `RttStats` (iş parçacığı güvenli pencere: `add(rttUs)`, `snapshot(reset)` → n, p50, p95, max; `format()` → `rtt_ms_p50_95_max=a/b/c rtt_n=N`, boşsa `-`). `TrafficClass.apply(requested, set, get)` → log alanları (istek yoksa hiçbir şey yapmaz; hata oturumu öldürmez). `WifiLockPolicy.shouldHold(enabled, transport, started, ui)` (Wi-Fi + açık + aktivite başlatılmış + yalnız `SessionUi.Connected`; uygularken daraltıldı) ve `WifiLockHolder` (sahte arka uçla test edilen idempotent acquire/release, her değişimde `wifi_lock held=…` logu).
2. **SessionMachine:** kurucuya `pingIntervalUs` (varsayılan `PING_INTERVAL_US` = 500 ms); PONG zaman aşımı aynı (3 s).
3. **SessionController:** `WifiKnobs` parametresi; motor tik'i `min(100, ping_ms)` (ping çözünürlüğü için, varsayılanda değişmez); kontrol ve video soketlerine `connect` öncesi `setTrafficClass`, bağlantı sonrası `getTrafficClass()` logu (`ev=traffic_class sock=control|video requested=… applied=…`). `session_start` logu: `transport=usb|wifi ping_ms=… tos_ctl=… tos_video=… wifi_ll=…`.
4. **MainActivity:** ekleri ayrıştır; `onPong`'da RTT örneği `RttStats`'a; oturum başında sıfırla. Saniyelik istatistik tikinde ayrı `MB/session ev=net transport=… rtt_ms_p50_95_max=… rtt_n=… ping_ms=…` satırı. WifiLock: `render()` (her UI durumu), `onStop`, `onDestroy`'da politika ile senkron; arka plan/bağlantı kopması/oturum sonu → bırakılır.
5. **Manifest:** `WAKE_LOCK` izni.
6. Testler: `WifiKnobsTest` (ayrıştırma, RTT penceresi, trafik sınıfı, kilit politikası/tutucu), `SessionMachineTest`'e ping aralığı testi. `./scripts/check.sh`.

## Handoff

- **Commit:** `1626023` (uygulama); plan `71b8222`; dal `task/T-089-client-wifi-knobs` (`main` 79c7495 üstünde).
- **Dokunulan dosyalar:** `session/WifiKnobs.kt` (yeni: `WifiKnobs`, `TrafficClass`, `RttStats`, `WifiLockPolicy`, `WifiLockHolder`), `session/SessionMachine.kt` (kurucuya `pingIntervalUs`), `session/SessionController.kt`, `MainActivity.kt`, `AndroidManifest.xml` (`WAKE_LOCK`), `test/.../session/WifiKnobsTest.kt` (yeni, 17 test), `test/.../session/SessionMachineTest.kt` (+`pingIntervalKnob`), bu kart.
- **check.sh:** ALL OK.
- **Ne değişti:**
  - `MB/session ev=session_start host=… port=… transport=usb|wifi quickack=… ping_ms=500 tos_ctl=- tos_video=- wifi_ll=0`. Ayrıca açılışta bir kez `ev=wifi_knobs` (aynı alanlar).
  - Saniyelik istatistik tikinde (yalnız akış varken, `ev=stats` satırlarıyla aynı anda) yeni satır: `MB/session ev=net transport=wifi rtt_ms_p50_95_max=1.20/3.40/8.90 rtt_n=2 ping_ms=500`. Pencere = son tikten bu yana gelen PONG'lar (en yakın sıra yüzdelikleri; sınır 1024 örnek). Varsayılan 500 ms ping'de pencerede ~2 örnek olur; anlamlı p95 için `--ei ping_ms 50/100`. Mevcut `rtt_us` (en iyi RTT, 8 örnek) `MB/render ev=stats` satırında değişmeden duruyor.
  - `--ei ping_ms N`: [20, 1000] aralığına sıkıştırılır (PONG zaman aşımı 3 s sabit kalsın diye). Motor tik'i `min(100 ms, ping_ms)`; varsayılanda 100 ms, yani davranış aynı. RTT, motorun ping zamanından PONG'un motorda işlenmesine kadardır (önceki `rtt_us` ile aynı ölçüm; motor kuyruğu beklemesi dahil).
  - `--ei tos_ctl N` / `--ei tos_video N` (0..255; aralık dışı = yok sayılır): `connect` öncesi `Socket.setTrafficClass(N)`, sonrası `MB/session ev=traffic_class sock=control|video requested=0xb8 applied=0x..` (`getTrafficClass()`). Hata oturumu öldürmez (`err=` alanı). Düğme yoksa sokete dokunulmaz, log yok.
  - `--ez wifi_ll true`: `WIFI_MODE_FULL_LOW_LATENCY` kilidi (referans sayımsız). Tutulur: düğme açık + uç nokta Wi-Fi (loopback değil) + aktivite başlamış + UI `Connected`. `render()` her UI durumunda, `onStop` (arka plan) ve `onDestroy`'da senkronlanır; `Disconnected`/`Failed`/`Idle`/`Searching`/`Connecting` ve USB'de bırakılır. Log: `MB/session ev=wifi_lock held=1|0 reason=<durum> mode=low_latency`. Edinme hatası bir kez loglanır, tekrar denenmez.
- **Varsayımlar:** `am start --ei` değeri `Integer.decode` ile ayrıştırır, yani `0xB8` çalışmalı; emin olmak için ondalık (184 / 136) kullanılabilir. Kart "`MB/session` satırı" dediği için RTT ayrı `ev=net` satırına kondu (mevcut `ev=stats` satırları `MB/render`/`MB/decoder`). Kilit `AwaitingApproval` sırasında tutulmaz (yalnız `Connected`). Girdi yolu değişmedi; yalnız soket seçeneği ve ping zamanlaması eklendi.
- **Test edilmeyenler / tablette doğrulanacaklar:**
  1. Varsayılan açılış (ek yok), Wi-Fi: `adb logcat -s 'MB/session:*'` → `session_start ... transport=wifi ... ping_ms=500 tos_ctl=- tos_video=- wifi_ll=0`; akış sırasında saniyede bir `ev=net transport=wifi rtt_ms_p50_95_max=…/…/… rtt_n=2`; `traffic_class` ve `wifi_lock` satırı YOK. USB'de `transport=usb`.
  2. `am start -n dev.matebridge.client/.MainActivity --ei ping_ms 50 --ei tos_ctl 184 --ei tos_video 136 --ez wifi_ll true` (Wi-Fi): `traffic_class sock=control requested=0xb8 applied=0xb8` ve `sock=video requested=0x88 applied=0x88` (applied farklı/`-1` ise HarmonyOS değeri ezmiş demektir, not edilmeli); `ev=net ... rtt_n=≈20 ping_ms=50`; bağlanınca `wifi_lock held=1 reason=connected`.
  3. Kilit bırakma: Ctrl+Shift+Esc / ana ekran → `wifi_lock held=0 reason=background`; geri dönünce tekrar `held=1`. Mac'te host'u kapat → `held=0 reason=disconnected`. İsteğe bağlı: `adb shell dumpsys wifi | grep -i -A3 lock` ile kilidin tutulduğu/bırakıldığı.
  4. Kalem/klavye/touchpad normal; ping_ms 50 iken oturum düşmüyor (PONG zaman aşımı yok), kopma/yeniden bağlanmada girdi takılı kalmıyor.
  5. (Ölçüm, orkestratör) kalem öbeklenmesi p95'i `tos_*` ve `wifi_ll` ile/olmadan karşılaştır (NOTES 2026-09-30 ~10 ms referans). DSCP'nin Mac/AP'ye ulaşıp ulaşmadığı Mac'te `tcpdump -v` ile `tos 0xb8` görünerek doğrulanabilir.
- **Açık sorular:** Aşağı yönde (Mac → tablet) video paketlerinin DSCP/WMM sınıfını host belirler; T-088 bunu `NWParameters.serviceClass` (`MATEBRIDGE_SERVICE_CLASS`) ile ele alıyor. Tabletteki `tos_video` yalnız tabletin video soketinden çıkan paketleri (ACK'ler, açılış PING'i) etkiler; `tos_ctl` ise kalem/girdi yukarı yönü için asıl düğme. `ev=net` yalnız video akarken yazılır (istatistik tiki renderer'a bağlı); onay bekleme sırasında RTT logu yok.

