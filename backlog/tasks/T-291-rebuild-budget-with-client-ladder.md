---
id: T-291
title: Host + istemci — tekrarlayan medya hatasında yeniden kurma bütçesini istemcinin kurtarma merdiveniyle birlikte tasarla
status: todo
phase: 6
owner: orchestrator
depends_on: [T-289, T-200]
decisions: [0019]
files:
  - backlog/tasks/T-291-rebuild-budget-with-client-ladder.md
---

## Amaç

T-289 codex incelemelerinden (2026-10-07) ayrıldı. Host'un pipeline yeniden deneme bütçesi (`PipelineRetryPolicy`) yalnız kendi zamanlayıcısıyla yapılan yeniden kurmaları sınırlıyor. Tablet videoya yeniden bağlanınca `onVideoAttached` pipeline'ı koşulsuz kuruyor; bu T-289'dan önce de böyleydi. Kalıcı bir kodlayıcı hatasında döngü saniyede ~1–2 kez dönebilir: pipeline kurulur, düşer, tablet 500 ms sonra yeniden bağlanır. T-200 bitene kadar her turda sanal ekran da yeniden kuruluyor.

Host tarafında yeniden bağlanmayı bekletme denendi (T-289 cf8962f6) ve geri alındı, çünkü iki sorun çıktı:
- tabletin `VideoHealth` merdiveni ~6 sn sonra oturumu yeniden kuruyor; bu politikayı sıfırladığı için bekleme boşa çıkıyor;
- eski bir zamanlayıcı olayı, yeni kurulan bağlantıyı iptal edebiliyor.

Cihazda hiç görülmedi.

## Kabul

1. Önce tasarım notu. İki taraf "kalıcı medya hatası" durumunu tek yerde mi tanıyacak, yoksa host bunu bir STREAM_CONFIG/BYE nedeniyle mi bildirecek? Protokol değişirse bu orkestratörün işi (PROTOCOL.md ve fixture'lar). T-200 ekranı koruyorsa döngünün bedeli küçülür; bu, kartın gerekliliğini de değiştirir.
2. Kalıcı hata altında video kalıcı olarak ölü kalmaz (Mac'in tek ekranı tablet), ve yeniden kurma sıklığı sınırlı olur.
3. Uygulama kartları tasarımdan sonra açılır.

## Plan

## Handoff

## Open questions
