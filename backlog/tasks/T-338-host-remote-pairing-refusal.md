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

## Handoff

## Open questions
