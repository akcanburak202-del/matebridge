---
id: T-361
title: Host — gizli imleç kilitlenmesi; gizliyken de hareket et, kenardan içeride tut
status: review
phase: 7
owner: mac-host-dev
depends_on: [T-272]
decisions: []
files:
  - host-mac/Sources/MateBridgeHost/Input/
  - host-mac/Sources/MateBridgeCore/Input/
  - host-mac/Tests/MateBridgeCoreTests/
  - docs/LOGGING.md
  - backlog/tasks/T-361-hidden-cursor-inset-move.md
---

## Amaç

Kullanıcı (2026-10-21/22): trackpad ile imleç zaman zaman hareket etmiyor; tıklama çalışıyor, imleç görünmüyor. Çoğu kez sol kenarda (Dock, otomatik gizleme açık) oluyor.

Kanıt (host.log + canlı yakalama 2026-10-22 13:57):
- Takılma anında `CGCursorIsVisible() == 0`, imleç (20,930), ön uygulama Safari (YouTube). Host `pointer_hidden_mode state=on`, saniyede 20–50 `POINTER_REL` geliyor, hepsi `pointer_hidden_n`. 11:41'de 40 sn+ (yeniden bağlanma da çözmedi), 11:58'de 10 sn.
- İmleç Mac'te 1 pt gerçekten kaydırılınca (`CGEvent mouseMoved` konum +1) imleç anında göründü.
- Neden: T-272 gizliyken konumu sabit tutuyor. Web sayfası (CSS `cursor: none`, video oynatıcı) imleci ancak konum gerçekten değişince geri gösteriyor → kısır döngü. Terminal'in "yazarken gizle"si sıfır hareketli olayla da açılıyor (16 ms'lik on/off satırları), o yüzden çoğu zaman sorun yok.
- Takılma Oyun modunda (oyun ekranı 1x) da oldu, yani mod ile sınırlamak çözmez.

## Kabul

1. İmleç **gizliyken** `POINTER_REL` imleci **hareket ettirir**: `location` = canlı imleç + delta, ekran sınırlarının **8 pt içine** sıkıştırılmış (sabit, adlandırılmış; tüm kenarlar). `mouseEventDeltaX/Y` bugünkü gibi ham hareket (kesirler taşınır). Böylece web sayfaları imleci geri gösterir, oyunda imleç kenara varmaz (Dock / menü çubuğu açılmaz, T-272'nin amacı korunur).
2. Gizliyken canlı imleç iç dikdörtgenin dışındaysa (ör. x=0) ilk hareket onu içeri alır; sıçrama ≤ 8 pt.
3. Görünürken davranış aynen (kenara kadar gider).
4. Düğme basılıyken (sürükleme) gizliyken de aynı kural; düğme olayları mevcut konumda. Hiçbir down/up kaybolmaz (AGENTS.md).
5. `POINTER_ABS`, kalem, dokunma, kaydırma değişmez.
6. Log: `pointer_hidden_mode` ve `pointer_hidden_n` kalır; LOGGING.md'de "gizliyken göreli hareket imleci kaydırmaz" cümlesi yeni davranışa göre güncellenir.
7. Testler (Core): gizliyken hareket konumu değiştirir (T-272 öncesi ve sonrası kırmızı, şimdi yeşil olan regresyon testi), iç dikdörtgene sıkıştırma (dört kenar), kenardaki canlı imlecin içeri alınması, kesir taşıma, gizli sürükleme down/up, gizli→görünür geçişi. Mevcut HID testleri yeni davranışa göre güncellenir (hangi beklentinin neden değiştiği Handoff'ta).

## Plan

1. Core: `DisplayGeometry.moved(_:dx:dy:inset:)` (normal clamp, then inset clamp; a display axis too small for the margin uses its center). `InjectionPlanner.hiddenCursorInset = 8`.
2. Planner: gizli `.relative` yolu görünür yolla aynı (canlı imleç + delta, `remember`) ama `inset` ile sıkıştırılır; `hiddenCursorMoves` sayacı kalır. `adoptLiveCursor`taki T-272 gizli kolu kalkar (artık kendi gönderimlerimiz imleci oynatıyor, gecikme süzgeci gerekli).
3. Host: yalnız yorum güncellemesi (örnekleme/log aynı). LOGGING.md cümlesi.
4. Testler: HID-1/3/4/5/6/8 yeni davranışa göre, HID-1b (dört kenar), HID-1c (kenardaki imleç içeri), HID-2b (görünür kenara kadar).

## Handoff

- Commit: son `T-361: ...` commit'i (branch `task/T-361-hidden-cursor-inset-move`).
- Dosyalar: `host-mac/Sources/MateBridgeCore/Input/{InjectionPlanner,Geometry+Display,MacEvent}.swift`, `host-mac/Sources/MateBridgeHost/Input/InputController.swift` (yalnız yorum), `host-mac/Tests/MateBridgeCoreTests/Input/HiddenCursorTests.swift`, `docs/LOGGING.md`, bu kart.
- Davranış: gizliyken `POINTER_REL` = canlı imleç + delta, 8 pt iç dikdörtgene sıkıştırılmış; delta ham, kesir taşınır. Görünür/ABS/kalem/dokunma/kaydırma değişmedi. Düğme yolu değişmedi (down/up kaybolmaz).
- Değişen HID beklentileri: HID-1/3/4/5/6 (konum artık sabit değil, hareket eder ve içeri sıkışır; T-272 kabulü 1 bilerek tersine çevrildi). HID-8: gizli dal `adoptLiveCursor`tan kalktığı için, oyunun imleci tam son gönderilen konumlardan birine geri sıçratması "gecikme" sayılır (görünür moddaki bilinen ödünleşim, pencere kısa); test, oyunun başka bir yere ortalamasıyla çalışır. HID-2/7/9 değişmedi. Yeni: HID-1b, 1c, 2b.
- Varsayım: `mouseMoved` konumu değişince WindowServer gizli imleci yine gösterir (kanıt: kartın canlı yakalaması, +1 pt). Oyunlarda imleç delta ile 8 pt içeride gezer; GameController oyunları etkilenmez.
- Gerçek donanımda EDİLMEDİ (CGEvent gönderilmedi): Safari/YouTube'da takılma düzeliyor mu; oyunda Dock/menü çubuğu hâlâ açılmıyor mu (Dock tetik bölgesi 8 pt'den dar olmalı, aksi halde inset artırılır); sol kenarda takılı imleç ilk harekette içeri geliyor mu.

## Open questions
