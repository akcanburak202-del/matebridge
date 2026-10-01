---
id: T-088
title: Mac — Wi-Fi ölçüm altyapısı ve düğmeler (aktarım logu, gönderim kuyruğu ölçümü, Wi-Fi bit hızı, serviceClass)
status: in_progress
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

Ön deney (scratch, commit edilmedi): loopback `NWListener`/`NWConnection` ile kabul edilen bağlantının çekirdek soketi
süreç fd tablosunda bulunuyor (`proc_pidinfo(PROC_PIDLISTFDS)` + `getsockname/getpeername` port eşleşmesi).
`getsockopt(TCP_CONNECTION_INFO)` `tcpi_srtt`, `tcpi_snd_sbbytes`, `tcpi_txretransmitpackets` veriyor. Ayrıca açık API
`NWProtocolTCP.Metadata.availableSendBuffer` aynı kuyruk baytını (`sbbytes`) döndürüyor. Bu, fd bulunamazsa yedek yol.

1. **Core (saf, testli)**
   - `Core/Session/TransportKnobs.swift`: `SessionTransport.logName` (`usb|wifi`); `ServiceClassKnob.parse`
     (`MATEBRIDGE_SERVICE_CLASS=off|video|signaling`, varsayılan off) → `TrafficClass?` video/kontrol eşlemesi
     (off: ikisi de nil = bugünkü; video: `.interactiveVideo`/`.responsiveData`; signaling: `.interactiveVideo`/`.interactiveVoice`);
     `SendQueueLogKnob.isEnabled(env)` (`MATEBRIDGE_LAT_TRACE=1` ya da `MATEBRIDGE_SENDQ_LOG=1`).
   - `VideoSettings`: `bitrateOverrideSource` (`env|wifi_env`), `bitrateSource` buna göre. Yeni
     `applyingTransportKnobs(env, transport:)`: aktarım Wi-Fi, env bit hızı yok ve `MATEBRIDGE_WIFI_BITRATE_KBPS`
     geçerliyse (5–150 Mbps) override = N, kaynak `wifi_env`. `applying(prefs)` override'ı zaten koruyor.
   - `Core/Video/SendQueueStats.swift`: `TcpSample` + `SendQueueMeter` (sınırlı örnek dizisi, pencere başına
     p50/p95/max KB, son srtt/rttvar, yeniden gönderilen paket farkı, cwnd/snd_wnd) → `logFields`.
2. **Host**
   - `Session/TcpSocketProbe.swift`: bağlantının yerel/uzak portlarıyla fd'yi bulur (yalnız okuma, fd asla kapatılmaz,
     her okumada portlar yeniden doğrulanır). Bulunamazsa `NWProtocolTCP.Metadata.availableSendBuffer` yedeği
     (yalnız kuyruk; `source=nw_metadata`).
   - `VideoLink`: knob açıksa her `send` öncesi örnek alır; `sendQueueWindow()`.
   - `SessionServer`: video ve kontrol için ayrı `tcpParameters(serviceClass:)`; `listening` log'una `service_class=`;
     `session_started` log'una `transport=`; aktarımı `SessionTransportBoard`'a (cihaz kimliğiyle, sınırlı) yazar
     (HELLO alınınca ve `sessionStarted`'da).
   - `Session/SessionTransportBoard.swift`: süreç içi küçük, kilitli tablo. Gerekçe: `StreamCoordinator` ile
     `SessionServer` `MateBridgeApp/main.swift`'te bağlanıyor ve o dosya kartın `files:` listesinde değil.
   - `StreamCoordinator`: `settings(for:)` aktarımı tablodan okur, `applyingTransportKnobs` uygular;
     `stream_session` log'una `transport=`; saniyelik tick'te `component=video ev=sendq`.
3. Testler (`Tests/MateBridgeCoreTests/Session/TransportKnobsTests.swift`, `Video/SendQueueStatsTests.swift`),
   `./scripts/check.sh`, Handoff.

## Handoff

