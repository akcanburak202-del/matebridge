---
id: T-338
title: Host — uzaktan eşleşme yasağı (yerel olmayan eşe PAIRING yerine REJECTED)
status: review
phase: 7
owner: mac-host-dev
depends_on: [T-336, T-337]
decisions: [0038, 0018]
files:
  - host-mac/Sources/MateBridgeCore/Session/
  - host-mac/Sources/MateBridgeHost/Session/
  - host-mac/Sources/MateBridgeHost/Security/
  - host-mac/Tests/
  - backlog/tasks/T-338-host-remote-pairing-refusal.md
---

## Amaç

Karar 0038 §5 ve ek madde 1; PROTOCOL.md §3 adım 3 "Uzaktan eşleşme yok". Dal tabanı: `task/0038-remote-integration` (T-337 birleştikten sonra).

## Kapsam

1. Saf, test edilebilir bir sınıflandırıcı (`MateBridgeCore`): eş adres + arayüz listesi (ad, bayraklar, adres, maske/önek, kapsam) → `local` / `remote`. Kurallar PROTOCOL.md'deki gibi: loopback (IPv4-mapped dahil), `en*` + `IFF_UP` doğrudan bağlı alt ağ (IPv4 maske, IPv6 önek, link-local yalnız kapsam `en*`), `100.64.0.0/10` her zaman uzak, belirlenemeyen = uzak.
2. Host tarafı: `getpeername` + `getifaddrs` ile girdileri toplar; PAIRING gerekecek her yerde (yeni cihaz, anahtar yok) eş uzaksa şifresiz `HELLO_ACK(REJECTED, NONE)` + kapanış; onay penceresi açılmaz; `ev=pairing_refused reason=remote` (adres loglanmaz ya da yalnız sınıfı loglanır). PAIRED yolu değişmez.
3. Sıralama: ret, onay penceresi ya da bekleyen eşleşme durumu oluşmadan önce verilir; 0018'in bağlantı-sonrası onay yolu (yetim onay) uzak eşte hiç başlamaz.

## Kabul

- Sınıflandırıcı birim testleri: 127.0.0.1, ::1, ::ffff:127.0.0.1, 192.168.1.20 (en0 192.168.1.0/24) yerel; 192.168.2.20 (başka alt ağ) uzak; 100.101.102.103 uzak; utun arayüzündeki alt ağa düşen eş uzak; fe80::1%en0 yerel, fe80::1%utun3 uzak; arayüz listesi boş → yalnız loopback yerel.
- Oturum testi: uzak eşten anahtarsız HELLO → REJECTED/NONE, onay isteği oluşmaz; uzak eşten PAIRED → bugünkü gibi kabul.
- `./scripts/check.sh` geçer.
- Codex `--high` incelemesi (güvenlik).

## Plan

1. `MateBridgeCore/Session/PeerLocality.swift`: saf `PeerClassifier.classify(peerHost:interfaces:)` -> `PeerLocality` (`local`/`remote`). Eş `"adres[%kapsam]"` metni; arayüz = `LocalInterface(name, isUp, address, prefixLength)`. IPv4-mapped IPv4 sayılır; `127/8` ve `::1` yerel; `100.64/10` her zaman uzak; `en*` + up + ön ek >= 8 eşleşmesi yerel; link-local yalnız kapsam `en*` ve up ise yerel; ayrıştırılamayan = uzak. Link-local gömülü kapsam baytları (KAME) sıfırlanır.
2. `SessionMachine`: `connectionOpened(_:now:peer:)` (varsayılan `.local`, yalnız mevcut testler için; üretim çağrısı açıkça verir). Bağlantıda saklanır. Anahtarsız (PAIRING gerekecek) yolda eş uzaksa `HELLO_ACK(REJECTED, NONE)` + close + `pairing_refused reason=remote`; `handleHello` içinde (anahtar kesin yoksa, BUSY/orphan kontrolünden önce) ve `continueHello` başında (arama sonucu anahtarsızsa). Bekleyen durum, `requestApproval`, orphan hiç oluşmaz. PAIRED yolu aynı.
3. Host: `BsdTcpConnection` kapsam kimliğini de verir (`peerScopeID`); `SessionServer` `getifaddrs`'tan (`NetworkInterfaces`) `LocalInterface` toplar, `PeerClassifier` ile sınıflar, `connectionOpened`'a verir. Adres loglanmaz.
4. Testler: sınıflandırıcı (kart listesi + ek durumlar), makine (uzak anahtarsız -> REJECTED/NONE, onay yok, orphan yok; uzak PAIRED kabul; yerel PAIRING bozulmaz).

## Handoff

- Dal `task/T-338-host-remote-pairing-refusal` (taban 5d76aa76). Kod commit: 82f2e838 (plan: ondan önceki commit; bu handoff commit'i ayrı).
- Dosyalar: yeni `MateBridgeCore/Session/PeerClassifier.swift` (`PeerLocality`, `LocalInterface`, `PeerClassifier.classify`), `SessionMachine.swift` (`connectionOpened(_:now:peer:)`, `refuseRemotePairing`), `BsdTcpSocket.swift` (`peerScopeID`), `MateBridgeHost/Session/NetworkInterfaces.swift` (`localInterfaces()` + `peerText`), `SessionServer.swift` (`acceptControl` sınıflar), testler `PeerClassifierTests` (14) ve `RemotePairingRefusalTests` (8). `Security/` dizinine dokunulmadı.
- Ret iki yerde: `handleHello` (uzak ve onay kaydı yok/`allowPaired` kapalı: BUSY ve orphan kontrolünden önce, böylece uzak eş oturum olup olmadığını öğrenmez) ve `continueHello` başı (arama sonucu anahtarsız; BUSY kontrolünden ve ECDH'den önce). Her ikisi şifresiz `HELLO_ACK(REJECTED, NONE)` + close + `pairing_refused reason=remote` (warning). Pending/onay/orphan/`lookupPairKey` oluşmaz; test bunu doğrular. Sürüm uyuşmazlığı hâlâ önce gelir.
- Varsayımlar: `connectionOpened`'ın `peer:` varsayılanı `.local` (yalnız 100 mevcut test çağrısı için); üretimde tek çağrı `acceptControl` ve her zaman açıkça sınıf verir. Sınıflandırma bağlantı başına yapılır (getifaddrs her seferinde okunur). Ön eki < 8 olan arayüz girdisi (örn. bozuk /0) yok sayılır; bitişik olmayan maskeli girdi `NetworkInterfaces`'te atlanır. KAME gömülü kapsam baytları (fe80:4::1) sıfırlanır. IPv6 kapsam adı `if_indextoname` ile çözülür; çözülemezse kapsamsız = uzak. Adres hiçbir yerde loglanmaz.
- Test edilmedi (donanım/ağ gerektirir): gerçek `getpeername`/`getifaddrs` çıktısı (özellikle macOS'ta link-local `sin6_scope_id`/gömülü kapsam, Tailscale `utun` ve Wi-Fi alt ağı), `adb reverse` loopback eşi, bir uzak eşten gerçek RET'in istemcide görünmesi. `peerScopeID` ek bir `getpeername` çağrısıdır.
- check.sh: Swift build+test geçer (1165 test). Gradle başarısız: beklenen Kotlin fixture-kapsam testi (T-339 yok). Not: `StallRestartTests.retryJoinsTheHangingReleaseAndRestartsOnceItCompletes` (T-338 ile ilgisiz, zamanlama yarışı) paralel derleme yükü varken iki kez düştü, yük yokken 5 koşuda geçti; taban 5d76aa76 da geçiyor.
- Codex `--high` incelemesi orkestratörde.

### Review düzeltmeleri (Codex P2 + orkestratör)

- Entegrasyon dalı (ff450dbe) birleştirildi; tam `check.sh` geçer (Kotlin dahil, 1167 Swift testi).
- P2: uzak eş onay kaydı olsa da BUSY kısayollarını (`persistingOrphans`, başka cihaz yuvası) atlar; anahtar önce çözülür. Anahtarsızsa REJECTED/NONE (BUSY sızıntısı yok), anahtarlıysa `continueHello` aynı BUSY kurallarını uygular. Eşzamanlı ve eşzamansız arama testli, anahtarlı uzak eşin BUSY'si de.
- `connectionOpened(_:now:peer:)` artık `peer` zorunlu (varsayılan yok, fail closed). `.local` veren aşırı yükleme yalnız test hedefinde (`RemotePairingRefusalTests.swift` içindeki extension). Önceki handoff'taki "varsayılan .local" notu geçersiz.

## Open questions
