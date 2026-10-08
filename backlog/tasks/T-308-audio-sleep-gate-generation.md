---
id: T-308
title: Host — ses uyku kapısı; kuyrukta bekleyen eski uyanma, yeni bir uykunun kapısını temizlemesin (uyku kuşağı)
status: todo
phase: 7
owner: mac-host-dev
depends_on: [T-299]
decisions: []
files:
  - host-mac/Sources/MateBridgeHost/Audio/SystemAudioTap.swift
  - host-mac/Sources/MateBridgeCore/Session/HostSleep.swift
  - host-mac/Tests/MateBridgeCoreTests/Session/
  - backlog/tasks/T-308-audio-sleep-gate-generation.md
---

## Amaç

T-299 Codex 5. tur P2. Senaryo: tap kuyruğu izin penceresi yüzünden uyku → uyanma → ikinci uyku boyunca bloklu kalıyor. İlk uyanmanın kuyruktaki işi ikinci uykunun `sleepGate`'ini temizliyor ve bekleyen başlatmayı geri yüklüyor; ikinci uykunun söküm adımı da bu yüzden atlanıyor. Sonuç: uyku geçişinde yakalama başlayabiliyor, ama log `audio=done` diyor. Girdi tarafı etkilenmiyor.

## Kabul

1. Kuyruktaki uyanma işi, kurulduğu uyku kuşağını taşır. Daha yeni bir uyku kapıyı yeniden kurduysa iş hiçbir şey yapmaz.
2. Kuşak mantığı saf Core'da (`HostSleepInputGate`'in yanında) ve test edilir.

## Plan

## Handoff

## Open questions
