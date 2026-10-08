---
id: T-304
title: Host — MATEBRIDGE_VD_TRANSFER anahtarını kaldır (karar 0032 eki); HDR10 aktarım ve primer kurulumu kalır
status: review
phase: 7
owner: mac-host-dev
depends_on: [T-302]
decisions: [0032]
files:
  - host-mac/Sources/MateBridgeHost/Video/VirtualDisplay.swift
  - host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift
  - host-mac/Sources/MateBridgeCore/Video/
  - host-mac/Tests/MateBridgeCoreTests/
  - backlog/tasks/T-304-host-vd-transfer-removal.md
---

## Amaç

Karar 0032 eki, 2026-10-08 (`docs/reviews/2026-10-08/agents/simp-f-knobs.md`, VD_TRANSFER satırı).

## Kabul

1. **Kaldırılanlar:** `vdTransferKnob` ve SDR akışta tf=1 ekranı kurma ya da yeniden kullanma durumu. HDR10 akışında aktarım işlevi ve P3 primer kurulumu (T-237/T-281) aynen kalır; `MATEBRIDGE_VD_PRIMARIES` kalır.
2. **Özel API:** `VirtualDisplay` tek özel API dosyası olmaya devam eder; başka dosya `CGVirtualDisplay`'e dokunmaz.
3. **Log:** `ev=vd_transfer` alanları HDR10 için anlamlı kalır; `requested` artık yalnız akıştan gelir.
4. **Test ve derleme:** testler ve derleme geçer. Cihazda bakılacak (orkestratör): Günlük'te SDR ve HDR açılışı, `vd_transfer applied` değerleri.

## Plan

`VideoSettings.vdTransferKnob` ve `VirtualDisplayTransfer.Knob/parse/envKey/invalid` silinir; `displayTransfer` yalnız akıştan türer (HDR10 -> 1, aksi 0, `UInt32`). `VirtualDisplay.init(transfer:)` UInt32 alır. `MATEBRIDGE_VD_TRANSFER` `ev=profile knobs=` izin listesinden çıkar. Testler buna göre güncellenir.

## Handoff

- Commit: `git log task/T-304-vd-transfer -1`. check.sh: ALL OK.
- Dosyalar: `MateBridgeCore/Video/{VirtualDisplayTransfer,VideoSettings,EncoderKnobs,GameDisplayPolicy,HDRPolicy}.swift`; `MateBridgeHost/VirtualDisplay.swift` (kartta `Video/` altı yazıyor, gerçek yol `MateBridgeHost/VirtualDisplay.swift`), `Session/StreamCoordinator.swift` (yalnız yorum); testler `HDRTests`, `VirtualDisplayPrimariesTests`, `VirtualDisplayTransferTests`.
- Kart listesi dışı, zorunlu iki küçük dokunuş: `Video/VideoDump.swift` (silinen `vdTransferKnob` atamasını kaldırdı) ve `Video/VideoPipeline.swift` (yalnız yorum).
- `outcome.invalidKnob` ve transfer için `reason=invalid_value` kalktı; `primaries_reason=invalid_value` (VD_PRIMARIES) aynen duruyor. `displayTransfer` türü `Knob` yerine `UInt32`. HDR10 yolu (tf=1, P3 primer, fallback, `hdr_fallback display_rejected`) değişmedi.
- Ortamda `MATEBRIDGE_VD_TRANSFER` artık sessizce yok sayılır (testle kanıtlı), `knobs=` alanında görünmez.
- Orkestratör güncellemeli (kapsam dışı): `docs/KNOBS.md` #43 satırı ve #45 metni, `docs/LOGGING.md` satır 272, 289, 298, 416.
- Cihazda doğrulanmadı: Günlük'te SDR açılış (`vd_transfer requested=0 applied=0`) ve HDR açılış (`requested=1 applied=1 primaries=p3`).

## Open questions
