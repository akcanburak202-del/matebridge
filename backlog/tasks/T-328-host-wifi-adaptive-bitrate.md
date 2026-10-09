---
id: T-328
title: Host — tıkanıklık denetleyicisini video kapısına ve kodlayıcıya bağla (Wi-Fi, anahtar) + canlı bit hızı ayarlayıcısını geri getir
status: todo
phase: 7
owner: mac-host-dev
depends_on: [T-327, T-326]
decisions: [0023]
files:
  - host-mac/Sources/MateBridgeCore/Session/TransportKnobs.swift
  - host-mac/Sources/MateBridgeHost/Session/SocketVideoTransport.swift
  - host-mac/Sources/MateBridgeHost/Session/SessionServer.swift
  - host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift
  - host-mac/Sources/MateBridgeHost/Video/VideoPipeline.swift
  - host-mac/Sources/MateBridgeHost/Video/
  - host-mac/Tests/MateBridgeCoreTests/Session/
  - docs/LOGGING.md
  - backlog/tasks/T-328-host-wifi-adaptive-bitrate.md
---

## Amaç

**T-196**'nın yeniden açılışı (0023 eki 2026-10-09). T-327 denetleyicisini video gönderim kapısına ve kodlayıcıya bağla; yalnız `transport == .network` ve anahtar açıkken. Canlı bit hızı ayarlayıcısı (T-177) 2026-10-08'de T-302 ile silindi; git geçmişinden geri getir (T-177 commitleri `6594e1a4`, `893b34c4`; silme `1fe10249`) ve denetleyicinin hedefini yeniden başlatmasız, keyframe'siz uygula.

## Bağlam

- **Tasarım:** `backlog/tasks/T-196-host-wifi-adaptive-send.md` *Bağlam*, *Kapsam dışı* ve *Kabul kriterleri* aynen geçerli (anahtar `MATEBRIDGE_WIFI_ADAPT=1` varsayılan kapalı; kapalıyken kapı davranışı birebir bugünkü; engellenen kabul yazılabilir **ve** tick'te yeniden denenir; `video ev=adapt` saniyelik log; USB'de hiç devreye girmez). Satır numaraları eski; HEAD'de yeniden doğrula. T-186/T-187/T-189 serileştirme notları artık geçersiz (birleşti).
- T-326 aynı dosyalara (`TransportKnobs.swift`, `SessionServer.swift`) dokunuyor: T-326 birleştikten sonra başla.
- T-302 sonrası `KNOBS.md` satırı 41-42 (canlı bit hızı) kaldırıldı olarak işaretli; yeni anahtar satırını Açık sorular'a yaz, orkestratör ekler.
- PROTOCOL §0x03 `bitrate_kbps` metni (tavan) orkestratörün işi; bayt/fixture değişmez.
- **Cihaz prosedürü (orkestratör):** Wi-Fi, Oyun 60 Mbps, sabit hareket sahnesi + ses, anahtar açık/kapalı iç içe ≥ 3 tur × 3 dk. Ölçüt: `queue_drops`, kontrol srtt p95, ses kesintisi, client fps, durağan metin netliği (5 s sonra tavana dönüş).

## Kapsam dışı

- T-196 *Kapsam dışı* ile aynı. Varsayılanı açmak (A/B sonrası orkestratör).

## Kabul kriterleri

- [ ] T-196 *Kabul kriterleri*'nin tamamı (cihaz maddeleri orkestratörün).
- [ ] [XCTest] Canlı ayarlayıcı: hedef değişimi kodlayıcı sahibinin kuyruğundan geçer, birikenler birleştirilir (T-177 davranışı), boru hattı yeniden başlamaz, keyframe istenmez.
- [ ] Codex incelemesi (taşıma değişikliği) çalıştırıldı, bulgular çözüldü (orkestratör).
- [ ] `./scripts/check.sh` geçiyor.

## Plan

_(Ajan kodlamadan önce doldurur.)_

## Handoff

_(Ajan bitirince doldurur.)_

## Open questions
