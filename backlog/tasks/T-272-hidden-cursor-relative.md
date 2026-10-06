---
id: T-272
title: Host — imleç gizliyken göreli hareket imleci kaydırmasın (oyunda Dock/menü çubuğu açılmasın)
status: review
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

1. Core: `InjectionEnvironment.cursorHidden` (varsayılan false). `InjectionPlanner`: `.relative` + `cursorHidden` iken konum = canlı imleç (ekranda ise), yoksa son bilinen, yoksa merkez; delta bugünkü gibi kesir taşıyarak; `remember` çağrılmaz (hiçbir gönderimiz imleci oynatmıyor); `Counters.hiddenCursorMoves`.
2. Host: `CursorVisibilityChecking` + `SystemCursorVisibility` (`CGCursorIsVisible`, dlsym, yoksa görünür). `InputController` her `POINTER_REL`'de örnekler (önbellek yok, ~ns), değişimde `ev=pointer_hidden_mode state=on|off`, `input_age` satırına `pointer_hidden_n`.
3. Testler: `HiddenCursorTests` (HID-1..7). LOGGING.md.

## Handoff

- Commit: son commit `T-272: ...` (`git log task/T-272-hidden-cursor-relative`).
- Dosyalar: `host-mac/Sources/MateBridgeCore/Input/{MacEvent,InjectionPlanner}.swift`, `host-mac/Sources/MateBridgeHost/Input/{CursorLocator,InputController}.swift`, `host-mac/Tests/MateBridgeCoreTests/Input/HiddenCursorTests.swift`, `docs/LOGGING.md`, bu kart.
- check.sh: geçti (swift test host-mac 926 test, HID suite dahil). Not: ilk çalıştırmada bir Android birim testi (Migration/WifiKnobs/InputHandoff paketlerinden biri, bu görevle ilgisiz) bir kez kırmızı çıktı, aynı kodla ikinci çalıştırmada yeşil: aralıklı (flaky) görünüyor, dokunulmadı.
- Varsayımlar: gizli = `CGCursorIsVisible() == 0` (T-271 kaydı); sembol yoksa "görünür". Yalnız `POINTER_REL` etkilenir (`cursorHidden` yalnız o mesajda örneklenir); `POINTER_ABS`, kalem, dokunma, kaydırma aynı. Gizliyken konum = canlı imleç örneği (ekran üzerindeyse); `adoptLiveCursor`'ın gecikme mantığı gizli yolda kullanılmıyor, çünkü kendi gönderimlerimiz imleci oynatmıyor. Düğme basma/bırakma yolu değişmedi (`cursor` önbelleği = canlı konum). Hiçbir up/release yolu değişmedi.
- Codex --high P2 düzeltmesi: gizliyken canlı örnek `adoptLiveCursor`'da görünür moddaki gecikme (lag) süzgecinden geçmiyor; her `POINTER_REL` için (yalnız düğme içeren, hareketsiz mesajlar dahil) doğrudan önbellekteki konum oluyor ve `recentTargets` boşaltılıyor. Böylece oyun imleci görünür bir hareketten hemen sonra gizleyip merkeze aldığında, hareketsiz tıklama eski konuma değil canlı konuma iner; up da aynı yerde, hiç düşmeden gönderilir. Testler: HID-8 (tam bu sıra, down + up, model boşta), HID-9 (down gizliyken, up görünürken: up düşmez).
- check.sh: düzeltmeden sonra ALL OK (Android `PackedRendererTest` bir çalıştırmada aralıklı kırmızı çıktı, ilgisiz; sonraki çalıştırmada yeşil).
- Test EDİLMEDİ (gerçek donanım/oyun gerekir; CGEvent gönderilmedi, imleç oynatılmadı): gizli imleçte WindowServer'ın aynı `location` + delta'lı `mouseMoved` olaylarını imleci sabit tutup delta olarak iletmesi (kartın varsayımı: fiziksel fare + `CGAssociateMouseAndMouseCursorPosition(false)` davranışı).
- Cihazda kontrol (kullanıcı):
  1. BT mouse/trackpad ile imleci gizleyen oyun açıkken imleci aşağı/yukarı sürmek Dock'u ve menü çubuğunu açmamalı.
  2. `host.log`: oyun imleci gizleyince `input ev=pointer_hidden_mode state=on`, gösterince `state=off`; oyun sırasında `input_age ... pointer_hidden_n=` sıfırdan büyük.
  3. Oyun dışında normal imleç hareketi, tıklama ve sürükleme eskisi gibi; yazarken imleç gizlenince (metin alanı) fare hareketi sonrası imleç normal geri gelmeli ve kenara kaçmamalı.
  4. Gizliyken sol tuş basılı sürükleme + bırakma sonrası düğme takılı kalmamalı.
  5. Oyun GameController kullanıyorsa (RE4) fare yine oyunda çalışmaz; bu kart onu çözmez (kabul 8).

## Open questions
