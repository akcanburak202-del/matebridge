---
id: T-326
title: Host — Wi-Fi öncelik sınıfları kabloda kayboluyor (Ethernet'te DSCP 0); açık IP_TOS anahtarı ve A/B
status: todo
phase: 7
owner: mac-host-dev
depends_on: []
decisions: [0023]
files:
  - host-mac/Sources/MateBridgeCore/Session/TransportKnobs.swift
  - host-mac/Sources/MateBridgeCore/Session/BsdTcpSocket.swift
  - host-mac/Sources/MateBridgeHost/Session/SessionServer.swift
  - host-mac/Tests/MateBridgeCoreTests/Session/TransportKnobsTests.swift
  - host-mac/Tests/MateBridgeCoreTests/Session/BsdTcpSocketTests.swift
  - docs/KNOBS.md
  - docs/LOGGING.md
  - backlog/tasks/T-326-host-explicit-dscp.md
---

## Amaç

T-124 kontrol/ses bağlantısını `NET_SERVICE_TYPE_VO`, videoyu `NET_SERVICE_TYPE_VI` yapıyor (`ServiceClassKnob.signaling`, varsayılan). Bu, Mac'in kendisi Wi-Fi'deyken Mac'in radyosunda WMM sınıfını seçiyordu (T-124 ölçümü o topolojide yapıldı). Bugün Mac **Ethernet'te** (`en0`), tablet Wi-Fi'de. Tablete giden paketlerin AP'de hangi WMM kuyruğuna gireceğini yalnızca IP başlığındaki DSCP belirler.

`ifconfig -v en0` (2026-10-09): `qosmarking enabled: yes mode: none` ve `sysctl net.qos.policy.*` hepsi 0. xnu `mode: none`'da servis türünden DSCP yazmaz → paketler büyük olasılıkla **DSCP 0** ile çıkıyor, ses/kontrol AP'de 60 Mbps videonun arkasında aynı kuyrukta bekliyor (NOTES 2026-10-08/09: Oyun 60 Mbps'te kontrol srtt 58–70 ms, ses kesintileri).

Bu kart: (1) kabloda DSCP'yi doğrula, (2) host'a açık `IP_TOS` anahtarı ekle (varsayılan kapalı), (3) cihazda A/B; sonuç iyiyse orkestratör varsayılanı değiştirir.

## Bağlam

- Kod: `BsdTcpSocket.swift` `adopt()` içinde `SO_NET_SERVICE_TYPE` best-effort ayarlanıyor; `BsdTcpOptions.serviceClass`. Knob: `TransportKnobs.swift` `ServiceClassKnob` (`MATEBRIDGE_SERVICE_CLASS`). Listener'lar `SessionServer.swift` (kontrol ~:271, video ~:478, log ~:959).
- Dosyalar soketi (`FilesSocket.swift`) zaten `NET_SERVICE_TYPE_BK`; bu kartta dokunulmaz.
- AP eşlemesi bilinmiyor. İki yaygın eşleme:
  - Eski 3 bit öncelik (Linux `cfg80211_classify8021d`, birçok ev AP'si): UP = DSCP >> 3. EF (46) → UP 5 = **AC_VI**; CS6 (48) → UP 6 = **AC_VO**; AF41 (34) → UP 4 = AC_VI.
  - RFC 8325: EF → UP 6 (AC_VO), AF41 → UP 4 (AC_VI).
  - Bu yüzden kontrol için iki aday değer A/B'lenir: EF `0xB8` ve CS6 `0xC0`. Video: AF41 `0x88`.
- macOS'ta `setsockopt(IPPROTO_IP, IP_TOS)` yetki istemez. `SO_NET_SERVICE_TYPE` ile birlikte ayarlandığında hangisinin kazandığı **ölçülecek** (tcpdump). Gerekirse anahtar açıkken servis türü ayarlanmaz.
- Wi-Fi'de tablet → Mac yönü (kalem) tabletin kendi radyosunda; bu kartın kapsamı dışında (gerekirse ayrı istemci kartı).

## Kapsam dışı

- Uyarlamalı bit hızı (0023 (c), ayrı kart).
- İstemci soket sınıfları, protokol değişikliği (tel aynı).
- Varsayılanı değiştirmek (A/B sonrası orkestratör).

## Kabul kriterleri

- [ ] [XCTest] `MATEBRIDGE_IP_TOS` ayrıştırma: `off` (varsayılan, bugünkü davranış birebir), `ef` (video 0x88, kontrol 0xB8), `cs6` (video 0x88, kontrol 0xC0), `video=0x..,control=0x..` biçimi; geçersiz değer → `off` + uyarı alanı. Sınırlar: 0–255, düşük 2 bit (ECN) sıfırlanır.
- [ ] [XCTest] `BsdTcpOptions` IP_TOS taşır; `adopt()` ayarlar (best effort, hata fatal değil); gerçek soket çiftinde `getsockopt(IP_TOS)` beklenen değeri okur.
- [ ] Log: dinleyici satırına (`listening`/servis sınıfı alanlarının yanına) `ip_tos=off|video=0x88,control=0xb8`; ayar başarısızsa bağlantı başına bir kez `W net ev=ip_tos_failed errno=`.
- [ ] `docs/KNOBS.md` yeni satır, `docs/LOGGING.md` alanı.
- [ ] [device, orkestratör] Kabloda doğrulama: `sudo tcpdump -i en0 -n -v host <tablet>` her iki bağlantıda `tos` değerini gösterir (anahtar kapalı ve açık). Sonuç NOTES'a.
- [ ] [device, orkestratör] A/B (Wi-Fi, Oyun 60 Mbps, sabit hareket sahnesi + ses tonu, arm başına 3 dk, iç içe off/ef/cs6/off/ef/cs6): kontrol srtt p50/p95, ses `owd` p95/max, `audio_arrival_gap` sayısı, underrun, video `queue_drops`, tablet ping. Bütçe (0023): kontrol srtt p95 ≤ 40 ms, 5 dk'da ≤ 1 ses kesintisi.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

_(Ajan kodlamadan önce doldurur: adımlar, dokunulacak dosyalar, riskler.)_

## Handoff

_(Ajan bitirince doldurur.)_

## Open questions
