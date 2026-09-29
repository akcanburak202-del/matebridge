---
id: T-010
title: Mac oturum sunucusu — Bonjour, kontrol bağlantısı, onay, heartbeat
status: todo
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

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
