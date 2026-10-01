---
id: T-097
title: Ses gecikmesi — sessizlik aralarını alt taşma saymamak, tablet tampon boyu, AAudio MMAP denemesi (karar gerekir)
status: todo
phase: 5
owner: orchestrator
depends_on: [T-095]
decisions: [0011]
files:
  - docs/NOTES.md
  - backlog/tasks/
---

## Amaç

NOTES 2026-10-01 ~20:50:
- Ses ~170–190 ms, video ~51 ms.
- Tablette yalnızca 20 ms'lik MIXER çıkışı var (FastMixer yok). `aaudio.mmap_policy=2`.
- Sessizlikte host IO'su durduğu için tablet alt taşma sayıyor ve hedef tamponu büyütüyor.

Kullanıcı farkı göze batan bulmadı; acil değil.

## Plan (orkestratör)

1. Sessizlik: tampon boşken veri gelmemesini (host IO yok) alt taşmadan ayır; güvenlik payını büyütme. Yeniden başlarken hedef seviyeyle hemen çal.
2. `buf_frames` 1920 → 960 denemesi.
3. AAudio MMAP sondası (NDK + karar kaydı): gerçek çıkış gecikmesi ölçümü. Kazanç ≥ 40 ms ise uygulama kartı.
