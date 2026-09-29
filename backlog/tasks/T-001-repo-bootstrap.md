---
id: T-001
title: Repo iskeletini kur ve GitHub'a yayınla
status: done
phase: 0
owner: orchestrator
depends_on: []
decisions: [0002, 0004]
files:
  - ./
---

## Amaç

Çok ajanlı çalışmaya hazır bir repo: ajan kuralları (AGENTS.md), backlog, karar kayıtları, log kuralları, tek doğrulama betiği. Public GitHub reposu ve noreply e-posta.

## Kapsam dışı

- Uygulama kodu (probe'lar ayrı kartlarda).
- CI (GitHub Actions). Derlenecek kod olunca ayrı kartla eklenecek.

## Kabul kriterleri

- [x] AGENTS.md + CLAUDE.md + alan AGENTS.md'leri
- [x] backlog (README, şablon, Aşama 0 kartları, board.sh)
- [x] docs/decisions 0001–0004, docs/LOGGING.md, docs/PROTOCOL.md iskeleti
- [x] scripts/check.sh, scripts/codex-review.sh
- [x] Kullanıcı iskeleti onayladı
- [x] `git init`, noreply e-posta ile ilk commit
- [x] `gh repo create matebridge --public` + push

## Plan

Orkestratör doğrudan yapar.

## Handoff

- **Commit:** d0e036c — https://github.com/akcanburak202-del/matebridge
- **Açık sorular:**
