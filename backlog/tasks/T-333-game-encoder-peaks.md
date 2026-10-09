---
id: T-333
title: Oyun 60 — kodlayıcı kare boyutu tepeleri (LLRC/ConstantBitRate, kısa rate penceresi, MaxAllowedFrameQP) EncodeBench karşılaştırması
status: todo
phase: 7
owner: mac-host-dev
depends_on: [T-330]
decisions: []
files:
  - host-mac/Sources/MateBridgeHost/Video/EncodeBench.swift
  - host-mac/Sources/MateBridgeCore/Video/EncodeBench.swift
  - host-mac/Sources/MateBridgeApp/EncodeBenchCommand.swift
  - host-mac/Tests/MateBridgeCoreTests/Video/EncodeBenchTests.swift
  - docs/NOTES.md
  - backlog/tasks/T-333-game-encoder-peaks.md
---

## Amaç

`docs/research/2026-10-10-optimization.md`, B1 + B2. Oyun modunda 60 Mbps'te Wi-Fi kuyruklanıyor, 30 Mbps'te temiz. Hipotez: suçlu ortalama değil, tek tek karelerin **tepeleri**. Bu kart yalnız ölçüm içindir; ürün koduna dokunulmaz.

## Kapsam

1. EncodeBench'te aynı içerik (kaydedilmiş ya da sentetik hareketli), 2800×1840 @60, üç kol:
   - (a) bugünkü fast profil, 60 Mbps;
   - (b) LLRC, kabul edilirse `ConstantBitRate` ile, 45 Mbps;
   - (c) fast profil + oturum kurulurken `MaxAllowedFrameQP` + 33 ms rate penceresi.
2. Çıktı:
   - kodlama süresi p50/p99 (ms);
   - kare boyutu ortalama, p99, maks ve p99/ortalama oranı (bayt);
   - varsa PSNR ya da SSIM.
3. Kollar sırayla değil, **iç içe** (ABCABC) koşar, çünkü NOTES'ta GPU saati karıştırıcı çıktı.
4. Mac'te pencere açılmaz; tablet tek ekran.

## Kabul

NOTES'a bir tablo ve öneri eklenir: hangi kol cihazda A/B denemesine değer. Ürün değişikliği ayrı bir kartta yapılır.

## Plan

## Handoff

## Open questions
