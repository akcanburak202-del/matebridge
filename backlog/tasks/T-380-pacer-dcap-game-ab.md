---
id: T-380
title: Ölçüm — Oyun 60'ta tablet geç kare atması (late_drops ~%12); pacer D tavanı A/B (pace_dcap_half 2/3/4)
status: done
phase: 7
owner: orchestrator
depends_on: []
decisions: []
files:
  - docs/NOTES.md
  - backlog/tasks/T-380-pacer-dcap-game-ab.md
---

## Amaç

2026-10-25 21:09–21:18 (NOTES): Oyun 30 Mbps, ağ temiz (srtt ~10, retx 0), host 60 kare gönderiyor ama tablet `render ev=present late_drops=85 slot_dups=85` / 10,5 sn, `skip_pct=11.7`. `d_jitter_us=21335` > `d_cap_us=16666` (n = 1 için yerleşik tavan 2 yarım periyot). Hipotez: varış oynaması tavanı aşınca kare yuvasını kaçırıyor. Kod yok; mevcut geliştirici anahtarı (`--ez dev true --ei pace_dcap_half N`, T-251; yalnız debug yapıda) ile A/B.

## Kabul

1. Aynı oyun oturumunda, aynı bit hızında, kollar: yerleşik (2), 3, 4. Her kol ≥ 3 dk.
2. Kol başına: tablet `skip_pct`, `late_drops`/dk, `shown_p95/p99`, `cap_dec` p50/p95 (eklenen gecikme), `d_jitter_us`, host tarafı temizlik (retx, write_ms) ile.
3. Sonuç NOTES'a. Bir kol belirgin iyiyse (skip ≥ yarıya iner, cap_dec p50 ≤ +8 ms) Oyun modu varsayılanı için karar kaydı + istemci kartı açılır.

## Plan

- Debug APK (main) kurulur; kollar `am force-stop` + `am start --ez dev true --ei pace_dcap_half N` ile değiştirilir; kullanıcı her kolda yeniden bağlanır (0042: otomatik bağlanma yok).

## Handoff

- Ölçüm 2026-10-25 21:47–22:00, sonuç NOTES aynı tarih. Yerleşik ayar en iyi (skip medyan 0,9; dcap 3/4: %25–32, cb_missing 10×). Varsayılan değişmez, kod yok.

## Open questions

- `late_drops` yerleşik kolda ~6/sn iken `fps` medyanı 59,5 ve `skip_pct` medyanı 0,9: sayaçlar aynı şeyi saymıyor gibi; görünür atlamanın asıl ölçütü hangisi (SurfaceFlinger `--latency` ile çapraz kontrol) ayrı incelenmeli.
