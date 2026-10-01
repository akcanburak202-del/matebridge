---
id: T-088
title: Mac — Wi-Fi ölçüm altyapısı ve düğmeler (aktarım logu, gönderim kuyruğu ölçümü, Wi-Fi bit hızı, serviceClass)
status: todo
phase: 5
owner: mac-host-dev
depends_on: [T-086]
decisions: []
files:
  - host-mac/Sources/MateBridgeHost/Session/
  - host-mac/Sources/MateBridgeHost/Video/
  - host-mac/Sources/MateBridgeCore/Video/
  - host-mac/Sources/MateBridgeCore/Session/
  - host-mac/Tests/
  - backlog/tasks/T-088-host-wifi-knobs.md
---

## Amaç

Wi-Fi modu çalışması (orkestratör araştırması, 2026-10-01 ~17:40):

- Host `maxInFlight=2` gerçekte kareyi tutmuyor. `.contentProcessed` kare çekirdek tamponuna kopyalanınca geliyor (`write_done - write_start` p50 0,32 ms). Asıl kuyruk sınırsız ve ölçülmeyen çekirdek gönderim tamponu.
- Host log'u oturumun aktarımını (USB/Wi-Fi) yazmıyor.
- `StreamPrefsPolicy` aktarımı dikkate almıyor.

Bu kart **ölçüm** ve **düşük riskli deney düğmeleri** ekler. Varsayılan davranış değişmez; aktarım alanı yalnızca log'a eklenir.

## Kabul kriterleri

- [ ] `session_started` ve `stream_session` log'larına `transport=usb|wifi` eklenir (`SessionTransport.classify` zaten hesaplıyor).
- [ ] Video bağlantısının çekirdek gönderim kuyruğu ölçülür, saniyede bir `ev=sendq` log satırı yazılır: `sendq_kb_p50_95_max`, `rtt_ms` (varsa `tcp_info`/`TCP_CONNECTION_INFO`: `tcpi_srtt`, `tcpi_snd_sbbytes`, yeniden gönderilen segmentler). Gerekirse Network.framework bağlantısından alttaki soket tanımlayıcısına güvenli erişim kullanılır. Erişilemiyorsa nedeni Handoff'a yazılır, yerine `netstat` örneklemesi önerilir. Yalnız `MATEBRIDGE_LAT_TRACE=1` ya da yeni `MATEBRIDGE_SENDQ_LOG=1` açıkken.
- [ ] `MATEBRIDGE_WIFI_BITRATE_KBPS=N`: oturum Wi-Fi ise prefs varsayılanı yerine N kullanılır. `MATEBRIDGE_BITRATE_KBPS` verilmişse o kazanır. Log `bitrate_source=wifi_env`.
- [ ] `MATEBRIDGE_SERVICE_CLASS=video|signaling|off` (varsayılan off = bugünkü). Video dinleyicisi için `NWParameters.serviceClass` `.interactiveVideo`, kontrol için `.responsiveData` (`signaling`'de `.interactiveVoice`). Video ve kontrol için ayrı parametre üretimi gerekiyor.
- [ ] Saf mantık (bit hızı önceliği, aktarım sınıflaması, sendq istatistiği) testli.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

(ajan doldurur, commit eder, sonra uygular)

## Handoff

