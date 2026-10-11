---
id: T-338
title: Host — uzaktan eşleşme yasağı (yerel olmayan eşe PAIRING yerine REJECTED)
status: todo
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

## Open questions
