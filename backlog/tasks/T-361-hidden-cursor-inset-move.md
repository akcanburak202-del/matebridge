---
id: T-361
title: Host — gizli imleç kilitlenmesi; gizliyken de hareket et, kenardan içeride tut
status: in_progress
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

## Handoff

## Open questions
