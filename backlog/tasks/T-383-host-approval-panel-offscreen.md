---
id: T-383
title: Host — onay penceresi ekransızken açılınca ekran gelince görünür olsun
status: todo
phase: 7
owner: mac-host-dev
depends_on: []
decisions: [0018]
files:
  - host-mac/Sources/MateBridgeApp/ApprovalPanel.swift
  - host-mac/Sources/MateBridgeApp/main.swift
  - host-mac/Sources/MateBridgeCore/PanelPlacement.swift
  - host-mac/Tests/MateBridgeCoreTests/PanelPlacementTests.swift
  - docs/LOGGING.md
  - backlog/tasks/T-383-host-approval-panel-offscreen.md
---

## Amaç

2026-10-27: ikinci tablet (Xiaomi) ilk eşleşmede `approval_shown conn=15` aldı; o anda MatePad bağlı değildi, Mac başsız (hiç ekran yok). Xiaomi ayrıldı (`approval_disconnected`, pencere 2 dk açık kalır), 1,2 s sonra MatePad bağlandı ve sanal ekran kuruldu; kullanıcı onay penceresini **görmedi**. Olası sebep: `ApprovalPanel.show()` `panel.center()`'ı ekran yokken çağırıyor, pencere sonra gelen sanal ekranın dışında kalıyor.

## Kabul

1. Onay penceresi açıkken ekran yapılandırması değişirse (`NSApplication.didChangeScreenParametersNotification`; sanal ekranın kurulması dahil) pencere ana ekranda yeniden ortalanır ve öne getirilir (`.floating` korunur). Gözlemci pencere kapanınca/dismiss olunca kaldırılır.
2. Pencerenin çerçevesi hiçbir ekranla kesişmiyorsa da aynı şey yapılır (ekran değişimi bildirimi kaçsa bile, ör. `show()` anında ekran yoksa bir sonraki ekran bildiriminde).
3. Pencere ekranı varken açıldıysa ve kullanıcı taşıdıysa, ilgisiz bir ekran değişimi pencereyi yalnızca ekran dışında kaldıysa yeniden konumlandırır (kullanıcının konumu boşuna bozulmaz). Basitlik için "her değişimde ortala" seçilirse Plan'da gerekçelendir.
4. `ev=approval_repositioned reason=screen_change|offscreen` (info) loglanır; `docs/LOGGING.md` gerekiyorsa güncellenir (dosya listesine ekle ya da Open questions'a yaz).
5. Onay mantığı, kod, zaman aşımları değişmez. Mac'te pencere açma testi YOK (Mac'in tek ekranı tablet; ajanlar GUI açmaz). Mantık saf bir yardımcıya ayrılabiliyorsa (çerçeve ekranlarla kesişiyor mu) birim testi yaz.
6. `./scripts/check.sh` geçer.

## Plan

Saf yardımcı `PanelPlacement.isOffscreen` (Core, test edilir): pencerenin ≥%50'si tek bir ekranda değilse true. `ApprovalPanel.show()` ekran var mı kaydeder ve `didChangeScreenParametersNotification` gözlemcisi ekler; bildirimde: show ekransız yapıldıysa koşulsuz yeniden ortala (`screen_change`), değilse yalnızca offscreen ise ortala (`offscreen`; kullanıcının konumu korunur, kabul 3). Ortalarken `.floating` + öne getir. Gözlemci `dismiss()`'te kalkar (cevap da dismiss'ten geçer). main.swift `approval_repositioned` loglar. Dosya listesine Core yardımcısı, test ve LOGGING.md eklendi.

## Handoff

## Open questions
