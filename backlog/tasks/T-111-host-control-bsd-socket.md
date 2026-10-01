---
id: T-111
title: Mac — kontrol bağlantısını (girdi, ses, kontrol mesajları) çekirdek TCP soketine taşı (T-091'in kontrol karşılığı)
status: todo
phase: 5
owner: mac-host-dev
depends_on: [T-091, T-092]
decisions: []
files:
  - host-mac/Sources/MateBridgeHost/Session/
  - host-mac/Sources/MateBridgeCore/Session/
  - host-mac/Sources/MateBridgeApp/main.swift
  - host-mac/Tests/
  - backlog/tasks/T-111-host-control-bsd-socket.md
---

## Amaç

T-091/T-092 video bağlantısını NWConnection'dan (kullanıcı alanı TCP, Wi-Fi'de %4 yeniden gönderim) çekirdek BSD soketine taşıdı. Wi-Fi gecikmesi 372 ms'den ~40 ms'ye indi.

Kontrol bağlantısı hâlâ NWConnection. Bu bağlantıda şunlar var:
- C→H tüm girdi (kalem, klavye, touchpad);
- H→C ses paketleri (karar 0011, 100 paket/sn);
- kontrol mesajları.

Açık gözlemler:
- Wi-Fi'de kalem örnekleri bazen toplu geliyor (NOTES, memory).
- Oyun modunda ses paketlerinde 25–30 ms'lik gecikmeler var (T-110 analizi).

Aynı yığına geçmek iki tarafa da tutarlılık getirir.

## Kabul kriterleri

- [ ] Kontrol dinleyici ve bağlantıları çekirdek TCP soketiyle çalışır. T-091'deki video BSD soket yapısı yeniden kullanılır; kopya kod olmaz, ortak katman çıkarılabilir.
  - `TCP_NODELAY` açık.
  - Uygun `SO_SNDBUF`/`TCP_NOTSENT_LOWAT`, Plan'da gerekçesiyle. Ses ve küçük mesajlar için düşük gecikme öncelikli.
  - `SO_KEEPALIVE`/zaman aşımı davranışı NWConnection'dakiyle eşdeğer.
- [ ] `MATEBRIDGE_CONTROL_SOCKET=bsd|nw` ayarı (varsayılan `bsd`), video ayarıyla aynı kalıpta. `nw` eski yolu birebir korur. Seçilen yol `ev=` loglarında görünür.
- [ ] Davranış birebir aynı:
  - çerçeveleme, şifreleme, devralma (SUPERSEDED), BYE;
  - 5 sn HELLO zaman aşımı;
  - bağlantı kopunca release-all (§7);
  - USB tüneli (127.0.0.1) ve Wi-Fi;
  - `transport=` tespiti;
  - `TcpSocketProbe`/`ev=sendq` (gerekirse kontrol için de).
- [ ] Girdi asla takılı kalmaz: soket hatası, yarım kapanma ve EOF yolları release-all'u tetikler. Testlerle gösterilir.
- [ ] Ses gönderimi bloklanmaz; sınırlı kuyruk kuralı (§5, ses ≤100 ms) korunur.
- [ ] Testler: loopback üzerinde gerçek soketle HELLO→ACCEPTED→girdi→kopma→release-all; büyük ve küçük mesaj sırası; `nw` geri dönüşü.
- [ ] `./scripts/check.sh` geçiyor. Cihaz testi orkestratörde (USB ve Wi-Fi, kalem ve ses).

## Plan

(ajan doldurur, commit eder, sonra uygular)

## Handoff
