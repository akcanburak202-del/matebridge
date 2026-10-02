---
id: T-124
title: Host — Wi-Fi'de varsayılan servis sınıfı `signaling` (kontrol/ses AC_VO, video AC_VI)
status: review
phase: 5
owner: mac-host-dev
depends_on: []
decisions: []
files:
  - host-mac/Sources/MateBridgeCore/Session/TransportKnobs.swift
  - host-mac/Sources/MateBridgeHost/Session/SessionServer.swift
  - host-mac/Tests/MateBridgeCoreTests/
  - docs/LOGGING.md
  - backlog/tasks/T-124-host-wifi-service-class-default.md
---

## Amaç

NOTES 2026-10-02 ~12:45. Mac de Wi-Fi'de (en1, 5 GHz kanal 52, 160 MHz; Ethernet bağlı değil). Ses AUDIO_FRAME'leri kontrol bağlantısında, video ile aynı kablosuz kuyruklardan geçiyor.

`MATEBRIDGE_SERVICE_CLASS=signaling` ile (kontrol `interactiveVoice` = AC_VO, video `interactiveVideo` = AC_VI) aynı Krita pinch + Apple Music testi:

| ayar | süre | alt taşma | > 100 ms boşluk |
|---|---|---|---|
| `off` | 3 dk | 8 | var |
| `signaling` | 5,5 dk | 8 | yok (en büyük ~75 ms) |

Kullanıcı: "kesinti sanki azaldı". T-088'de servis sınıfının video verimine zararı görülmedi.

## Kapsam dışı

- USB yolu (adb tüneli; sınıf etkisiz, zararsız).
- Tablet → Mac yönü (istemci soketleri).

## Kabul kriterleri

- [x] `ServiceClassKnob` varsayılanı `signaling` olur. `MATEBRIDGE_SERVICE_CLASS=off` eski davranışı geri getirir.
- [ ] BSD kontrol ve video soketlerinde `SO_NET_SERVICE_TYPE` gerçekten uygulanır ve loglanır. Uygulanamazsa uyarı satırı yazılır. **Kısmen:** uygulandığı birim testiyle doğrulandı (kabul edilen sokette VO/VI okunuyor) ve `ev=listening` yapılandırılan sınıfları yazıyor. Bağlantı başına "uygulandı" logu ve hata durumunda uyarı satırı `files:` dışında bir değişiklik istiyor (bkz. Açık sorular).
- [x] `ev=listening` satırı yeni varsayılanı gösterir. `docs/LOGGING.md` güncellenir.
- [x] Birim testi: ayrıştırma varsayılanı ve `off`.
- [x] `./scripts/check.sh` geçiyor.

## Plan

1. `TransportKnobs.swift`: `ServiceClassKnob.parse` için varsayılan `.signaling` olur (nil, boş ya da tanınmayan değer → `signaling`, diğer düğmelerle aynı kural). Yalnızca açık `off` eski davranışı (sınıf yok) verir; `video` aynen kalır. ~~`service_class_source` alanı~~: eklenmedi. `service_class=<ad>` zaten etkin değeri gösteriyor, ek alan gereksiz bulundu.
2. `SessionServer.swift`: `ev=listening` yeni alanları taşır. BSD kontrol/video bağlantısı kabul edildiğinde `SO_NET_SERVICE_TYPE` gerçekten uygulandı mı kontrol edilir ve loglanır; uygulanamazsa `warning` satırı yazılır. **Engellendi:** bkz. Açık sorular.
3. Testler (`TransportKnobsTests`): varsayılan (`nil`, boş, tanınmayan, boş ortam) → `signaling`; `off` → sınıf yok; log alanları. Ek olarak `BsdTcpSocketTests`: varsayılan sınıflar kabul edilen sokette gerçekten VO/VI, `off` ise BE.
4. `docs/LOGGING.md`: `ev=listening` açıklaması.
5. `./scripts/check.sh`, Handoff, commit.

## Handoff

- **Commit:** `1ebf0f1` (uygulama), plan `784109b`, bu Handoff ayrı bir commit.
- **Dokunulan dosyalar:** `host-mac/Sources/MateBridgeCore/Session/TransportKnobs.swift` (varsayılan `signaling`, `defaultValue`), `host-mac/Sources/MateBridgeHost/Session/SessionServer.swift` (yalnızca yorum; `ev=listening` zaten `serviceClass.logFields` yazıyordu), `host-mac/Tests/MateBridgeCoreTests/Session/TransportKnobsTests.swift`, `host-mac/Tests/MateBridgeCoreTests/Session/BsdTcpSocketTests.swift` (`testDefaultServiceClassIsAppliedToAcceptedSockets`), `docs/LOGGING.md`.
- **Varsayımlar:** Tanınmayan değer (ör. `voice`) artık `off` yerine varsayılana (`signaling`) düşer. Bu, `MATEBRIDGE_VIDEO_SOCKET` ve `MATEBRIDGE_CONTROL_SOCKET` ile aynı kural. `nw` dinleyicileri de (`tcpParameters`) aynı knob'dan beslendiği için onlar da artık varsayılan olarak sınıflı.
- **Test edilmeyenler / cihazda doğrulanacaklar:** Host uygulaması yeniden başlatılmadı, cihaz testi yapılmadı. Doğrulanacaklar: (1) ortam değişkeni olmadan `ev=listening ... service_class=signaling video_class=interactiveVideo control_class=interactiveVoice`; (2) `MATEBRIDGE_SERVICE_CLASS=off` ile `service_class=off`; (3) Wi-Fi'de Krita pinch + Apple Music sırasında > 100 ms ses boşluğu olmaması ve video veriminin düşmemesi; (4) USB yolunda gerileme olmaması.
- **Açık sorular:**
  - **Bağlantı başına uygulama logu ve uyarı (kriter 2) `files:` dışı.** `SO_NET_SERVICE_TYPE`, `host-mac/Sources/MateBridgeCore/Session/BsdTcpSocket.swift` içindeki `BsdTcpConnection.adopt` tarafından `try?` ile sessizce ayarlanıyor. Tanımlayıcı (`fd`) private olduğu için `SessionServer` sonucu ne okuyabiliyor ne de hatayı görebiliyor. Önerilen küçük değişiklik `BsdTcpSocket.swift`'te: `adopt` hatayı yutmak yerine `BsdTcpConnection` üzerinde `serviceTypeError: BsdSocketError?` saklasın, ya da `public func netServiceType() -> Int32?` (`getsockopt(SO_NET_SERVICE_TYPE)`) eklensin. Sonra `SessionServer.acceptControl/acceptVideo` sınıf ayarlıysa geri okusun. Eşleşmezse ya da başarısızsa `ev=service_class_failed video=true|false wanted=<sınıf> error=…` (warning) yazsın. Başarı durumunda bağlantı başına satır yazılmayabilir, çünkü `ev=listening` yeterli. Orkestratör `BsdTcpSocket.swift`'i kapsama eklerse bu, aynı kartta ya da bir takip kartında yapılabilir.

**Orkestratör (2026-10-02):** bağlantı başına uyarı satırı bu kartta yapılmayacak. `BsdTcpSocketTests.testDefaultServiceClassIsAppliedToAcceptedSockets` kabul edilen soketin `NET_SERVICE_TYPE_VO`/`_VI` aldığını doğruluyor, bu yeterli. Cihazda hata görülürse ayrı kart açılır.
