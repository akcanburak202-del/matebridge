---
id: T-272
title: Host — imleç gizliyken göreli hareket imleci kaydırmasın (oyunda Dock/menü çubuğu açılmasın)
status: todo
phase: 6
owner: mac-host-dev
depends_on: [T-271]
decisions: []
files:
  - host-mac/Sources/MateBridgeHost/Input/
  - host-mac/Sources/MateBridgeCore/Input/
  - host-mac/Tests/MateBridgeCoreTests/
  - docs/LOGGING.md
  - backlog/tasks/T-272-hidden-cursor-relative.md
---

## Amaç

Kullanıcı: tablete bağlı BT mouse ya da trackpad ile oyunda imleç aşağı inince Dock, yukarı çıkınca pencere/menü çubuğu açılıyor; Mac'e doğrudan bağlı mouse ile olmuyor. Neden: host `POINTER_REL`'de olayı `location = imleç + delta` ile gönderiyor (`CGEventPoster`, `MacEvent` "relative moves ... never clamped" deltalar + konum), gizli imleç de gerçekten kayıyor ve ekran kenarına varıyor. Fiziksel farede oyun imleci gizleyip ayırınca (`CGAssociateMouseAndMouseCursorPosition(false)`) WindowServer konumu sabit tutar, yalnız deltalar akar.

## Kabul

1. İmleç **gizliyken** (`CGCursorIsVisible() == false`; T-271 kaydı yazarken ve oyunda bunun doğru değiştiğini gösterdi, NOTES 2026-10-06 ~13:50) `POINTER_REL` olayı imleci hareket ettirmez: `location` = mevcut canlı imleç konumu (değişmeden), `mouseEventDeltaX/Y` = gelen hareket (bugünkü gibi kesirler taşınır). Görünürken bugünkü davranış aynen.
2. Gizlilik denetimi ucuz ve güvenli: `CGCursorIsVisible` dlsym ile (yoksa her zaman "görünür" say → bugünkü davranış); her `POINTER_REL`'de çağrılabilir (~2 ns) ya da kısa önbellek.
3. Düğme basılıyken (sürükleme) ve gizliyken de konum sabit; düğme olayları da mevcut konumda.
4. `POINTER_ABS`, kalem, dokunma, kaydırma değişmez.
5. Girdi durumu kuralları (AGENTS.md): hiçbir up/release kaybolmaz; bu yalnız konum hesabı.
6. Log: durum değişince bir satır (`ev=pointer_hidden_mode on|off`), saniyelik sayaçlara gizli moddaki hareket sayısı.
7. Testler (Core): gizli/görünür geçişinde konum hesabı, kesir taşıma, sürükleme.
8. Not: GameController (`GCMouse`) kullanan oyunlar (RE4) CGEvent görmez; bu kart onların fare girdisini çözmez, yalnız Dock/menü çubuğunun açılmasını engeller.

## Plan

(ajan doldurur)

## Handoff

## Open questions
