---
id: T-240
title: Host — apply STREAM_PREFS.chroma (decision 0033) via the T-235 sharp_nearest path; codec field rename
status: todo
phase: 6
owner: mac-host-dev
depends_on: [T-235, T-237]
decisions: [0033]
files:
  - host-mac/Sources/MateBridgeCore/
  - host-mac/Sources/MateBridgeHost/Video/
  - host-mac/Sources/MateBridgeHost/Session/
  - host-mac/Tests/
  - docs/LOGGING.md
  - docs/KNOBS.md
  - backlog/tasks/T-240-host-chroma-pref.md
---

## Amaç

Decision 0033'ün host tarafı. Protokol ve fixture'lar `task/T-239-chroma-protocol` dalında; **bu dalın üzerine kur** (`git checkout -b task/T-240-host-chroma task/T-239-chroma-protocol`). Protokolü değiştirme.

## Bağlam

- Codec: `STREAM_PREFS` grubundaki `reserved` → `chroma` (fixture `stream_prefs_hdr` alan adı değişti, bayt aynı; yeni `stream_prefs_sharp_chroma`). Bilinmeyen değer → 0. Yazma kuralı: grup `dynamic_range ≠ 0 || chroma ≠ 0` ise.
- Politika: `ChromaPolicy` girdi önceliği: env `MATEBRIDGE_CHROMA` > `STREAM_PREFS.chroma` (1 → `sharp_nearest`) > normal. HDR10 kuralı (T-237 birleşimi) aynen: HDR uygulanınca yok sayılır, `reason=hdr`.
- Değişim yeni `config_id` ile; ekran yeniden kurulmaz, yalnız yakalama biçimi + Metal geçişi değişir. Cihaz başına hatırlanan tercih `chroma`'yı da taşır (T-049 deposu).
- `ev=chroma_config` her yapılandırmada `source=env|prefs|default` ile; `ev=chroma_stats` yalnız keskin yol açıkken (bugünkü gibi).

## Kabul kriterleri

- [ ] [XCTest] Fixture'lar (yeni + adı değişen), politika önceliği, HDR kuralı, hatırlanan tercih.
- [ ] Varsayılan (chroma=0, env yok) yol T-235'teki varsayılanla bit-bit aynı.
- [ ] `./scripts/check.sh --only host,protocol` geçer (Kotlin fixture testi T-241'de).

## Plan

_(Ajan kodlamadan önce doldurur.)_

## Handoff

_(Ajan bitirince doldurur.)_
