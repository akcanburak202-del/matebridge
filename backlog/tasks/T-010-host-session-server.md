---
id: T-010
title: Mac oturum sunucusu — Bonjour, kontrol bağlantısı, onay, heartbeat
status: review
phase: 1
owner: mac-host-dev
depends_on: [T-008]
decisions: [0002]
files:
  - host-mac/Sources/MateBridgeCore/Session/
  - host-mac/Sources/MateBridgeHost/Session/
  - host-mac/Sources/MateBridgeApp/
  - host-mac/Tests/MateBridgeCoreTests/Session/
---

## Amaç

Tabletin Mac'i bulup bağlanabilmesi: PROTOCOL.md §2, §3 ve §6'nın host tarafı. Video ve girdi enjeksiyonu yok; video bağlantısı yalnızca kabul edilip doğrulanır.

## Kabul kriterleri

- [ ] Oturum durum makinesi `MateBridgeCore/Session`'da, saf ve birim testli: HELLO zaman aşımı, sürüm uyuşmazlığı, BUSY, aynı `device_id` ile devralma (eski oturum önce kapanır), PENDING → ACCEPTED/REJECTED, 60 sn onay süresi, 1,5 sn sessizlikte "release-all" olayı, 5 sn'de kapanma, PING→PONG, onay öncesi girdinin yok sayılması. Zaman soyutlanmış (test saatiyle).
- [ ] `MateBridgeHost/Session`: Network.framework ile TCP dinleyici (kontrol + video portu), `TCP_NODELAY`, Bonjour `_matebridge._tcp` (TXT `v=0`). Video bağlantısında `VIDEO_HELLO` `session_id`/`config_id` doğrulaması.
- [ ] Onaylı cihazlar `~/Library/Application Support/MateBridge/` altında kalıcı (yalnızca `device_id` ve ad). Menüde "Onaylı cihazları unut".
- [ ] `MateBridgeApp`: bağlantı isteğinde onay penceresi ("<ad> bağlanmak istiyor → İzin ver / Reddet"), menüde durum (dinliyor / bağlı: <ad>).
- [ ] `Info.plist` şablonuna `NSBonjourServices` ekleme ihtiyacı Açık sorular'a yazılır (dosya bu kartın dışında, orkestratör ekler).
- [ ] Test için: `nc` ve fixture baytlarıyla elle HELLO gönderip HELLO_ACK alındığı Handoff'ta gösterilir.
- [ ] Loglar `docs/LOGGING.md` formatında, cihaz adı loglanmaz.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

1. `MateBridgeCore/Session`: saf `SessionMachine` (olay -> eylem listesi, zaman `now` parametresiyle), `ApprovedDeviceStore` (JSON, 0600), `LogFormat`.
2. `MateBridgeHost/Session`: `SessionServer` (NWListener x2, TCP_NODELAY, Bonjour `_matebridge._tcp` TXT v=0, FrameDecoder, 100 ms tick), `SessionLogger` (os.Logger).
3. `MateBridgeApp`: durum satırı, onay NSAlert, "Onaylı cihazları unut", çıkışta `stop()`.
4. Birim testler: makine (BUSY, devralma sırası, onay, zaman aşımları, heartbeat, video doğrulama), store, log biçimi.

## Handoff

- **Commit:** `git log task/T-010-session-server` (tek T-010 commit'i)
- **Dokunulan dosyalar:** `Core/Session/{SessionMachine,ApprovedDeviceStore,LogFormat}.swift`, `Host/Session/{SessionServer,SessionLogger}.swift`, `MateBridgeApp/main.swift`, `Tests/.../Session/{SessionMachineTests,SessionSupportTests}.swift`, bu kart.
- **Varsayımlar:**
  - Kontrol portu dinamik (Bonjour); `adb reverse` için `SessionServer(controlPort:)` sabit port alır. Video portu her zaman dinamik.
  - HELLO'dan önce HELLO dışı mesaj = protokol hatası (BYE PROTOCOL_ERROR). Onay bekleyen oturum da tek oturum yuvasını tutar: başka cihaz BUSY alır; aynı `device_id` bekleyen oturumu da devralır.
  - HELLO zaman aşımında ve onay reddinde BYE gönderilmez (HELLO_ACK(REJECTED) / sessiz kapanış). Video bağlantısında 5 sn içinde VIDEO_HELLO gelmezse kapatılır (spesifikasyonda yok, eklendi).
  - `STREAM_CONFIG` yer tutucu: `SessionServer.defaultStreamConfig` (tabletin ekranı, nokta = piksel/2, H.264, 60 fps, 40 Mbit/s, config_id=1). T-011 gerçek değerleri `makeStreamConfig` ile verir. Ayar değişikliği (§3.7, yeni config_id) makinede henüz yok.
  - `releaseInput` ve `deliver` işleyicileri App'te boş; enjeksiyon sonraki görev. Tüm tetikleyiciler (RELEASE_ALL, BYE, kopma, protokol hatası, 1,5 sn sessizlik, devralma, kapanış) `SessionAction.releaseInput` ile hazır ve testli.
  - Log yalnızca os.Logger'a gider (`host.log` dosyası bu kartta yok). Cihaz adı hiçbir logda yok (test var).
  - `VideoLink` (Host/Session) doğrulanmış video bağlantısını T-011'e verir; T-011 farklı arayüz isterse orkestratör uyarlar.
- **Test edilmeyenler / cihazda doğrulanacaklar:** Ağ katmanı (NWListener, Bonjour yayını, TCP_NODELAY, kapatmada BYE'ın flush edilmesi) ve NSAlert akışı çalıştırılmadı (TCC/Local Network istemi tetiklememek için). `swift test` 61 test geçiyor, `check.sh` ALL OK.
  Elle deneme (uygulama çalışırken; portu `dns-sd -B _matebridge._tcp` ve `dns-sd -L <ad> _matebridge._tcp local` ile bul):
  `cd protocol/fixtures && (sed 's/#.*//' hello.hex | xxd -r -p; sleep 70) | nc 127.0.0.1 <control_port> | xxd`
  Beklenen: Mac'te onay penceresi; ilk yanıt `02 ..` HELLO_ACK status=1 (pending); "İzin ver" sonrası ikinci HELLO_ACK (status 0) ve `03 ..` STREAM_CONFIG.
- **Açık sorular:**
  - `Info.plist` şablonuna (kart dışı, orkestratör ekler): `NSBonjourServices` = [`_matebridge._tcp`]. Yayın için gerekmeyebilir ama Local Network izniyle birlikte koymak güvenli. `NSLocalNetworkUsageDescription` zaten var.
  - Onay penceresi `runModal` kullanıyor; bağlantı düşerse `abortModal` ile kapanıyor, gerçek uygulamada denenmeli.
  - `MateBridgeHost/Placeholder.swift` kart dışı olduğu için dokunulmadı.
