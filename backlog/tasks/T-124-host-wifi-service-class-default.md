---
id: T-124
title: Host — Wi-Fi'de varsayılan servis sınıfı `signaling` (kontrol/ses AC_VO, video AC_VI)
status: in-progress
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

- [ ] `ServiceClassKnob` varsayılanı `signaling` olur. `MATEBRIDGE_SERVICE_CLASS=off` eski davranışı geri getirir.
- [ ] BSD kontrol ve video soketlerinde `SO_NET_SERVICE_TYPE` gerçekten uygulanır ve loglanır. Uygulanamazsa uyarı satırı yazılır.
- [ ] `ev=listening` satırı yeni varsayılanı gösterir. `docs/LOGGING.md` güncellenir.
- [ ] Birim testi: ayrıştırma varsayılanı ve `off`.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

1. `TransportKnobs.swift`: `ServiceClassKnob.parse` için varsayılan `.signaling` olur (nil, boş ya da tanınmayan değer → `signaling`, diğer düğmelerle aynı kural). Yalnızca açık `off` eski davranışı (sınıf yok) verir; `video` aynen kalır. `logFields` her zaman `service_class=<ad> [service_class_source=env|default]` ile başlar; bunun için `ServiceClassSettings` benzeri bir kaynak bilgisi (`env`/`default`) eklenir ve test edilir.
2. `SessionServer.swift`: `ev=listening` yeni alanları taşır. BSD kontrol/video bağlantısı kabul edildiğinde `SO_NET_SERVICE_TYPE` gerçekten uygulandı mı kontrol edilir ve loglanır; uygulanamazsa `warning` satırı yazılır.
3. Testler (`TransportKnobsTests`): varsayılan (`nil`, boş, tanınmayan, boş ortam) → `signaling`; `off` → sınıf yok; log alanları.
4. `docs/LOGGING.md`: `ev=listening` açıklaması ve yeni uygulama/uyarı satırı.
5. `./scripts/check.sh`, Handoff, commit.

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
