---
id: T-088
title: Mac — Wi-Fi ölçüm altyapısı ve düğmeler (aktarım logu, gönderim kuyruğu ölçümü, Wi-Fi bit hızı, serviceClass)
status: review
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
  - host-mac/Sources/MateBridgeApp/main.swift
  - backlog/tasks/T-088-host-wifi-knobs.md
---

## Amaç

Wi-Fi modu çalışması (orkestratör araştırması, 2026-10-01 ~17:40):

- Host `maxInFlight=2` gerçekte kareyi tutmuyor. `.contentProcessed` kare çekirdek tamponuna kopyalanınca geliyor (`write_done - write_start` p50 0,32 ms). Asıl kuyruk sınırsız ve ölçülmeyen çekirdek gönderim tamponu.
- Host log'u oturumun aktarımını (USB/Wi-Fi) yazmıyor.
- `StreamPrefsPolicy` aktarımı dikkate almıyor.

Bu kart **ölçüm** ve **düşük riskli deney düğmeleri** ekler. Varsayılan davranış değişmez; aktarım alanı yalnızca log'a eklenir.

## Kabul kriterleri

- [x] `session_started` ve `stream_session` log'larına `transport=usb|wifi` eklenir (`SessionTransport.classify` zaten hesaplıyor).
- [x] Video bağlantısının çekirdek gönderim kuyruğu ölçülür, saniyede bir `ev=sendq` log satırı yazılır: `sendq_kb_p50_95_max`, `rtt_ms` (varsa `tcp_info`/`TCP_CONNECTION_INFO`: `tcpi_srtt`, `tcpi_snd_sbbytes`, yeniden gönderilen segmentler). Gerekirse Network.framework bağlantısından alttaki soket tanımlayıcısına güvenli erişim kullanılır. Erişilemiyorsa nedeni Handoff'a yazılır, yerine `netstat` örneklemesi önerilir. Yalnız `MATEBRIDGE_LAT_TRACE=1` ya da yeni `MATEBRIDGE_SENDQ_LOG=1` açıkken.
- [x] `MATEBRIDGE_WIFI_BITRATE_KBPS=N`: oturum Wi-Fi ise prefs varsayılanı yerine N kullanılır. `MATEBRIDGE_BITRATE_KBPS` verilmişse o kazanır. Log `bitrate_source=wifi_env`.
- [x] `MATEBRIDGE_SERVICE_CLASS=video|signaling|off` (varsayılan off = bugünkü). Video dinleyicisi için `NWParameters.serviceClass` `.interactiveVideo`, kontrol için `.responsiveData` (`signaling`'de `.interactiveVoice`). Video ve kontrol için ayrı parametre üretimi gerekiyor.
- [x] Saf mantık (bit hızı önceliği, aktarım sınıflaması, sendq istatistiği) testli.
- [x] `./scripts/check.sh` geçiyor.

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
     `session_started` log'una `transport=`; aktarımı `Handlers.sessionStarted` parametresiyle verir.
     (İlk sürümde `SessionTransportBoard` vardı; orkestratör kararıyla kaldırıldı, `main.swift` `files:`'a eklendi.)
   - `StreamCoordinator`: `sessionStarted(…, transport:)` → `applyingTransportKnobs` uygular;
     `stream_session` log'una `transport=`; saniyelik tick'te `component=video ev=sendq`.
3. Testler (`Tests/MateBridgeCoreTests/Session/TransportKnobsTests.swift`, `Video/SendQueueStatsTests.swift`),
   `./scripts/check.sh`, Handoff.

## Handoff


- **Commit:** `340a147` (uygulama), `5e93283` (orkestratör kapsam kararı: aktarım `Handlers.sessionStarted` ile,
  `SessionTransportBoard` silindi), `5ebf484` (plan). Dal `task/T-088-host-wifi-knobs`, `main` 79c7495 üzerinde.
- **check.sh:** ALL OK, `5e93283` sonrası yeniden çalıştırıldı (host-mac 216 XCTest + 508 swift-testing; yeni `TransportKnobsTests` 9, `SendQueueStatsTests` 5).
- **Dosyalar:**
  - Yeni (Core): `MateBridgeCore/Session/TransportKnobs.swift` (`SessionTransport.logName`, `TrafficClass`,
    `ServiceClassKnob`, `SendQueueLogKnob`), `MateBridgeCore/Video/TransportBitrate.swift` (`BitrateSource`,
    `applyingTransportKnobs`), `MateBridgeCore/Video/SendQueueStats.swift` (`TcpSample`, `SendQueueMeter`, `SendQueueWindow`).
  - Değişen (Core): `Video/VideoSettings.swift` (`bitrateOverrideSource`), `Video/EncoderKnobs.swift` (`bitrateSource`).
  - Yeni (Host): `Session/TcpSocketProbe.swift` (`TcpSocketProbe`, `SendQueueSampler`).
  - Değişen (Host): `Session/SessionServer.swift` (`Handlers.sessionStarted` artık 4. parametre `SessionTransport`),
    `Session/StreamCoordinator.swift` (`sessionStarted(sessionID:configID:hello:transport:)`).
  - Değişen (App): `MateBridgeApp/main.swift` (handler kapanışı transport'u koordinatöre geçirir; 2 satır).
  - Test: `Tests/MateBridgeCoreTests/Session/TransportKnobsTests.swift`, `Tests/MateBridgeCoreTests/Video/SendQueueStatsTests.swift`.
- **Log satırları:**
  - `component=session ev=session_started conn=… config_id=… video_port=… transport=usb|wifi`
  - `component=net ev=stream_session … bitrate_source=prefs|env|wifi_env codec=… transport=usb|wifi`
    (`stream_reconfigure` da `bitrate_source=wifi_env` yazar.)
  - `component=session ev=listening control_port=… video_port=… service_class=off` (ya da
    `service_class=signaling video_class=interactiveVideo control_class=interactiveVoice`).
  - Yalnız `MATEBRIDGE_SENDQ_LOG=1` ya da `MATEBRIDGE_LAT_TRACE=1` ile, saniyede bir (cadence tick'i):
    `component=video ev=sendq samples=N sendq_kb_p50_95_max=a/b/c rtt_ms=… rttvar_ms=… retx_pkts=… cwnd_kb=… snd_wnd_kb=… source=tcp_info|nw_metadata transport=…`.
    Hiç örnek alınamazsa bağlantı başına bir kez `ev=sendq_unavailable reason=no_endpoints|unavailable` (warning).
- **sendq ölçüm yöntemi:** Network.framework fd vermiyor. `TcpSocketProbe` bağlantının yerel/uzak portlarını
  (`currentPath.localEndpoint`, `endpoint`) alır, süreç fd tablosunda (`proc_pidinfo(PROC_PIDLISTFDS)`) `getsockname`/
  `getpeername` + `SO_TYPE == SOCK_STREAM` ile eşleşen soketi bulur, `getsockopt(TCP_CONNECTION_INFO)` ile okur
  (`tcpi_snd_sbbytes`, `tcpi_srtt`, `tcpi_rttvar`, `tcpi_txretransmitpackets`, `tcpi_snd_cwnd`, `tcpi_snd_wnd`).
  Yalnız okuma: fd asla kapatılmaz/yazılmaz, her okumadan önce iki port yeniden doğrulanır (fd numarası başka sokete
  geçmişse bırakılır). Bulunamazsa arama 120 örnekte bir tekrarlanır, arada `NWProtocolTCP.Metadata.availableSendBuffer`
  yedeği kullanılır (`source=nw_metadata`, yalnız kuyruk; macOS 27'de loopback'te `sbbytes` ile aynı değeri verdi).
  Örnek her kare yazımından **önce** alınır (bu karenin arkasında bekleyeceği birikim), `VideoLink.lock` dışında
  (NWConnection sorguları bağlantı kuyruğuna gidebilir; o kuyruktaki tamamlama işleyicileri bu kilidi alıyor).
  Doğrulama: gerçek `TcpSocketProbe` kaynağı + Core dosyalarıyla scratch bir harness (commit edilmedi), loopback
  NWListener/NWConnection üzerinde: `source=tcp_info sendq_kb…=223.5 rtt_ms=1 cwnd_kb=1231.8` (okumayan alıcı).
- **Varsayımlar / kararlar:**
  - **Aktarım taşıma yolu:** `SessionServer` `.sessionStarted` eyleminde kontrol bağlantısının eşinden aktarımı
    hesaplar (`SessionTransport.classify`) ve `Handlers.sessionStarted(sid, cid, hello, transport)` ile verir;
    `main.swift` bunu `StreamCoordinator.sessionStarted(…, transport:)`'a geçirir. Global tablo yok.
  - **Bilinen küçük tutarsızlık:** oturum makinesi ilk `STREAM_CONFIG`'i yalnız HELLO ile istiyor
    (`makeStreamConfig(hello)`), aktarım o anda bilinmiyor. Bu yüzden Wi-Fi'da `MATEBRIDGE_WIFI_BITRATE_KBPS` açıkken
    **ilk** `STREAM_CONFIG.bitrate_kbps` prefs/varsayılan değeri taşır; kodlayıcı ve sonraki (`STREAM_PREFS` sonrası)
    `STREAM_CONFIG`'ler Wi-Fi değerini taşır. Tablet bu alanı kullanmıyor (yalnız codec/boyut), etkisi yok.
  - "wifi" = loopback olmayan her eş (`SessionTransport.network`); kablolu LAN da `wifi` görünür.
  - `MATEBRIDGE_WIFI_BITRATE_KBPS` aralığı `MATEBRIDGE_BITRATE_KBPS` ile aynı (5 000–150 000); dışı yok sayılır.
    Değer `bitrateOverrideKbps` olarak saklandığından sonraki `STREAM_PREFS` ve kayıtlı prefs ile yeniden bağlanmada korunur.
    Yeniden yapılandırmadaki `STREAM_CONFIG.bitrate_kbps` de bu değeri taşır (ilk config için yukarıya bakın).
  - `signaling` modu kartta yazıldığı gibi: video `.interactiveVideo`, kontrol `.interactiveVoice` (`NWParameters.ServiceClass.signaling` kullanılmadı).
    Service class dinleyici parametresine konur; kabul edilen bağlantılar onu devralır.
  - `session_started` satırı `SessionMachine`'de üretiliyor (eş adresi bilmiyor); `transport=` alanı `SessionServer`
    `.log` işlenirken, hemen önceki `.sessionStarted` eyleminin hesapladığı `activeTransport`'tan ekleniyor.
  - Varsayılan davranış değişmedi: düğmeler kapalıyken yalnız log alanları eklendi, `serviceClass` set edilmiyor.
  - **Varsayılan yolda prob çalışmıyor (doğrulandı, kod okuması):** `SessionServer.sampleSendQueue` süreç başında bir
    kez `SendQueueLogKnob.isEnabled` ile okunur (`MATEBRIDGE_SENDQ_LOG=1` ya da `MATEBRIDGE_LAT_TRACE=1`).
    Kapalıyken `VideoLink.sendQueue` nil'dir; `SendQueueSampler` ve içindeki `TcpSocketProbe` hiç oluşturulmaz.
    `send()` içindeki tek ek iş `if let sendQueue, …` (nil, `canSend` bile çağrılmaz); `sendQueueReport()` nil döner,
    `ev=sendq` yazılmaz. fd tablosu taraması, `getsockname/getpeername`, `getsockopt` ve `NWConnection.metadata`
    çağrıları yalnız `TcpSocketProbe.sample()` içinde.
- **Test EDİLMEDİ (cihaz/izin gerekli):**
  - Uygulama yeniden başlatılmadı, `bundle-host.sh` çalıştırılmadı; gerçek oturumda hiçbir log satırı görülmedi.
  - Wi-Fi'da (`en0`) fd eşleşmesinin bulunduğu (`source=tcp_info`) ve `sendq_kb` değerlerinin anlamlı olduğu; loopback dışında doğrulanmadı.
  - USB oturumunda `transport=usb` (adb reverse → loopback eş) ve Wi-Fi'da `transport=wifi` görülmesi.
  - `MATEBRIDGE_SERVICE_CLASS=video|signaling` ile bağlantının kurulduğu ve paketlerin DSCP/WMM işaretini gerçekten
    taşıdığı (ör. `tcpdump -v` ile TOS alanı); tabletin/AP'nin bunu ödüllendirip ödüllendirmediği.
  - `MATEBRIDGE_WIFI_BITRATE_KBPS` ile Wi-Fi oturumunda `bitrate_source=wifi_env` ve kodlayıcının gerçek bit hızı.
- **Açık sorular:**
  - (Kapandı) Global tablo yerine `Handlers.sessionStarted` parametresi: orkestratör kararıyla `5e93283`'te yapıldı.
  - Yedek yol `NWConnection.metadata(definition:)` bağlantı kuyruğuna senkron gidiyor olabilir; örnekleme `VideoSender`
    Task'ından yapıldığı için kilitlenme yok, ama yalnız fd bulunamazsa ve düğme açıkken çalışıyor.
