---
id: T-032
title: Mac klavye — KEY → macOS keycode, değiştiriciler, otomatik tekrar, Caps Lock, release-all
status: review
phase: 3
owner: mac-host-dev
depends_on: [T-023]
decisions: [0003, 0008]
files:
  - host-mac/Sources/MateBridgeCore/Input/
  - host-mac/Sources/MateBridgeHost/Input/
  - host-mac/Tests/MateBridgeCoreTests/Input/
  - backlog/tasks/T-032-host-keyboard.md
---

## Amaç

PROTOCOL.md §4 `0x11 KEY` host kuralları ve §7 release-all'ın klavye kısmı. Bugün `InputStateMachine` KEY mesajını yok sayıyor. Karar 0003 (fiziksel tuş) ve 0008 (varsayılan değiştirici eşlemesi, ISO).

## Kabul kriterleri

- [ ] **Eşleme tablosu** (`MateBridgeCore`, saf): tuş kimliği (PROTOCOL: `scan_code` ya da `0x10000 + android_key_code`) → macOS virtual keycode. Tam ISO PC klavyesi: harfler, rakamlar, noktalama/TR tuşları (evdev 12, 13, 26, 27, 39, 40, 41, 43, 51, 52, 53, 86 dahil; karar 0008 ISO takası), Esc, Tab, Enter, Backspace, Space, Delete, Insert (Mac'te karşılığı yoksa `Help`/yok say — kararını Handoff'a yaz), oklar, Home/End/PgUp/PgDn, F1–F12, değiştiriciler (karar 0008 varsayılanı). Bilinmeyen kimlik → enjekte edilmez (debug log, yalnızca kimlik numarası).
- [ ] **Durum makinesi** (Core, saf, testli): basılı tuşlar kimlik → **enjekte edilen** keycode kaydıyla; UP kaydedileni bırakır. Zaten basılı tuşa ikinci DOWN ve basılı olmayana UP yok sayılır. Değiştiriciler `flagsChanged` olarak üretilir ve sonraki bütün tuş olaylarının flags'ine yansır (sol/sağ ayrımı dahil; iki taraf da basılıyken biri kalkınca flag düşmez).
- [ ] **Otomatik tekrar:** değiştirici olmayan **son** basılan tuş için host tekrar üretir; gecikme/aralık macOS ayarından (`NSEvent.keyRepeatDelay/keyRepeatInterval`, Core'a değer olarak geçer). Tekrar o tuşun UP'unda, başka bir tuşun DOWN'unda, release-all'da ve oturum sonunda durur. Tekrar olayları `keyboardEventAutorepeat = 1`. Zamanlama mevcut watchdog/`nextDeadline` düzenine oturur (ayrı zamanlayıcı yoksa); saf testlerde sahte saat.
- [ ] **Caps Lock** (PROTOCOL): Caps tuşu Mac'e tuş olarak enjekte edilmez; `lock_state.CAPS_LOCK` (Caps DOWN'u hariç) Mac'in durumundan farklıysa host Mac'in kilidini ayarlar (`IOHIDSetModifierLockState` ya da eşdeğeri; tek bir tipte, Core'dan soyutlanmış). Başarısızsa bir kez log.
- [ ] **Release-all / oturum sonu / kapı kapanması** (§7): bütün basılı tuşlar için UP (kayıtlı keycode), değiştiriciler için flags sıfırlayan `flagsChanged`, tekrar durur. Mevcut `InjectionPlanner` gölge durumu ve `OwedRelease` kuralları klavyeye genişler: **kapatan** olaylar (key up, modifier up) her zaman üretilir, başarısız gönderim tekrar denenir; açan olaylar yalnızca kapı açıkken.
- [ ] Sol düğme sahipliği ve kalem kuralları etkilenmez; mevcut testlerin hepsi geçer. Fuzz testi klavyeyi de kapsar: rastgele KEY + release-all + kapı değişimi → hiçbir tuş basılı kalmaz, çift down yok.
- [ ] **CGEvent** (`MateBridgeHost`): klavye olayları `CGEvent(keyboardEventSource:virtualKey:keyDown:)`, flags uygulanmış; kaynak klavye türü ISO (karar 0008; değeri Handoff'ta gerekçelendir). Posting yalnızca mevcut `CGEventPoster` üzerinden.
- [ ] **Gizlilik:** karakter ya da metin asla loglanmaz; keycode yalnızca `debug`. Sayaçlar (`key_msgs`, `unknown_keys`, `repeats`) `info` düzeyinde mevcut istatistik satırına eklenebilir.
- [ ] `--inject-test` için bir klavye seçeneği (ör. `--keys "cmd+a"` ya da fixture tabanlı) — yalnızca eklenir, ÇALIŞTIRILMAZ.
- [ ] `./scripts/check.sh` geçiyor. Mevcut `key_*` fixture'ları (varsa) Core testlerinde okunuyor.

## Kapsam dışı

- Tel biçimi ve PROTOCOL.md değişmez (değişmesi gerekiyorsa dur ve *Açık sorular*'a yaz).
- Ayar arayüzü (Faz 4), medya tuşları, Fn/halka tuşu.
- Gerçek olay gönderme yok. Cihaz testi orkestratörde: Türkçe karakterler (ğüşıöç, `"`, `<`, AltGr+Q=@), Cmd+C/V/Tab, tuş tekrarı, Caps Lock, uygulamayı arka plana alınca basılı kalan tuş olmaması.

## Plan

Mimari: klavye mevcut boru hattına (InputStateMachine → InjectionPlanner → OwedRelease/InputPipeline → CGEventPoster) eklenir; yeni zamanlayıcı yok.

1. **Core / `KeyMap.swift`** (saf): tuş kimliği → `KeyTarget` (`.key(vk)`, `.modifier(ModifierKey)`, `.capsLock`). evdev tablosu (ISO: 41 → 0x0A, 86 → 0x32; Insert → Help) + android_key_code yedek tablosu (android kodu → evdev). Değiştirici eşlemesi ayrı `ModifierMapping` (karar 0008 varsayılanı: Ctrl→Cmd, Alt→Option, Meta→Control). `KeyFlags` = CGEventFlags ham bitleri (aggregate + sol/sağ cihaz bitleri).
2. **Core / `InjectAction`**: `keyDown(keyCode, autorepeat)`, `keyUp`, `modifierDown/Up`, `setCapsLock(on)`. **`MacEvent.key(MacKey)`** (keyDown/keyUp/modifierDown/modifierUp, flags, isRepeat) ve **`.capsLock(on:)`**. `isClosing` = keyUp/modifierUp.
3. **Core / `InputStateMachine+Keyboard.swift`**: basılı kimlik → enjekte edilen kod kaydı; çift DOWN / basılmamış UP yok sayılır; aynı kodu iki kimlik tutarsa yalnızca ilk DOWN ve son UP üretilir; Caps tuşu enjekte edilmez (UP'ta `setCapsLock(lock_state)`), diğer her KEY olayından önce `setCapsLock(lock_state)`; otomatik tekrar (`nextDeadline`/`tick` düzenine, yapılandırılabilir gecikme/aralık, ileri/geri saat düzeltmesi); `releaseAll` tuş UP'ları + değiştirici UP'ları üretir, tekrarı durdurur; sayaçlar (`key_msgs`, `unknown_keys`, `repeats`).
4. **Core / `InjectionPlanner`**: gölge durum (basılı tuşlar, basılı değiştiriciler, Caps durumu); flags gölge durumdan hesaplanır (kapı yüzünden düşen bir değiştirici flags'e girmez); açan olaylar `openGate`, kapatanlar (key/modifier up) hiç kapılanmaz; tekrar yalnızca gölgede basılı tuş için; `releaseAll`/`notPosted` genişler. `InjectionEnvironment.capsLockOn: Bool?` (Mac'in durumu; yalnızca KEY mesajlarında örneklenir).
5. **Core / `OwedRelease`**: `Slot.key(vk)` ve `Slot.modifier(m)` (başarısız up tekrar denenir), `ReleaseRecord` sayaçları (`key_up`).
6. **Host**: `CGEventFactory` klavye olayı (keyDown/keyUp, flagsChanged, autorepeat alanı, klavye türü ISO); `.capsLock` için `CapsLockSetter` (IOHIDSetModifierLockState, tek tip, hata bir kez loglanır); `InputController` KEY için Caps durumunu örnekler, tekrar ayarlarını `NSEvent.keyRepeatDelay/Interval`'dan alır, sayaçları loglar; `--inject-test --keys "cmd+a"` (yalnızca eklenir, çalıştırılmaz).
7. **Testler**: eşleme tablosu, durum makinesi (çift down, kayıtlı keycode, sol/sağ değiştirici, tekrar zamanlaması, Caps), planner (kapı, flags), owed, pipeline, fuzz (klavye dahil, hiç tuş basılı kalmaz), `key_*` fixture'ları makine üzerinden.

## Handoff

- **Commit:** `ba38470` (kod) + bir handoff commit'i; dal `task/T-032-host-keyboard`. `./scripts/check.sh` → ALL OK (Core testleri dahil ~360 test; klavye: KMAP-*, KEY-*, PLAN-K*, KPIPE-*, KFUZZ-*).
- **Dokunulan dosyalar:**
  - Core (yeni): `Input/KeyMap.swift` (tablo, `ModifierKey`, `KeyFlags`, `ModifierMapping`), `Input/InputStateMachine+Keyboard.swift`.
  - Core (değişen): `InjectAction` (keyDown/keyUp/modifierDown/modifierUp/setCapsLock), `MacEvent` (`.key(MacKey)`, `.capsLock(on:)`, `InjectionEnvironment.capsLockOn`), `MacEvent+Closing`, `InjectionPlanner` (gölge durum + flags), `OwedRelease` (slotlar + bayat flags düzeltmesi), `ReleaseRecord`, `InputPipeline` (`setMachineConfiguration`), `InputStateMachine`.
  - Host: `CGEventPoster.swift` (klavye olayı, ISO türü), `CapsLock.swift` (yeni; `CapsLockControlling`/`SystemCapsLock`), `InputController.swift`, `InjectTest.swift` (`--keys`, `--key-hold`; ÇALIŞTIRILMADI).
  - Testler: yeni `KeyMapTests`, `KeyboardStateTests`, `KeyboardPlannerTests`, `KeyboardFuzzTests`; mevcutlarda yalnızca kapsamlı `switch`'lere klavye dalları (`InputTestSupport`, `InjectionPlannerTests`, `InputPipelineTests`) ve `SafetyTests` MISC-1 (KEY artık yok sayılmıyor).
- **Varsayımlar / kararlar:**
  - **Klavye türü:** `CGEventFactory.isoKeyboardType = 41` (`kbdtype` numaralandırması: 40 ANSI, 41 ISO, 42 JIS). Bu sayıyı belgeden değil bellekten aldım; **cihazda doğrulanmalı** (belirti: `"`/`<` tuşlarında yanlış karakter). Yalnızca event alanı (`keyboardEventKeyboardType`) ayarlanır, `CGEventSource`'a dokunulmaz. Yanlışsa tek sabit değişir.
  - **ISO takası:** evdev 41 → 0x0A (`kVK_ISO_Section`), evdev 86 → 0x32 (`kVK_ANSI_Grave`) (karar 0008).
  - **Insert** → `Help` (0x72). Num Lock, Scroll Lock, SysRq, Menu, medya tuşları eşlenmedi (bilinmeyen sayılır).
  - **Caps Lock API:** `IOHIDSetModifierLockState(conn, kIOHIDCapsLockState, on)` (mutlak durum, toggle değil; okuma `IOHIDGetModifierLockState`), tek tipte (`SystemCapsLock`, `CapsLockControlling` arkasında). `MacEvent.capsLock(on:)` Core'dan soyut; Mac durumu `InjectionEnvironment.capsLockOn` ile (yalnızca KEY mesajlarında örneklenir) gelir, planner farklıysa olay üretir. Hata `caps_lock_set_failed` olarak bir kez loglanır, batch durmaz, bir sonraki KEY mesajı yeniden dener. Caps Lock açıkken olayların explicit `flags` değeri `.capsLock` bitini taşır (yoksa flags ataması Caps bitini düşürür ve harfler küçük çıkar).
  - **Caps semantiği:** Caps DOWN hiçbir şey yapmaz; Caps UP ve diğer her KEY olayı (bilinmeyen/yinelenen dahil) `lock_state`'i uygulatır, olaydan önce.
  - **Flags** planner'ın kendi gölge durumundan (basılı değiştiriciler) hesaplanır: kapıda düşen bir değiştirici sonraki tuşun flags'ine girmez. Aggregate bit + sol/sağ cihaz biti ayrı tutulur; iki taraf basılıyken biri kalkınca aggregate kalır.
  - **Otomatik tekrar:** makinenin `nextDeadline`/`tick` düzeninde; değiştirici olmayan son DOWN tekrarlar; başka **her** kabul edilmiş DOWN (değiştirici dahil) durdurur; geç zamanlayıcı tek tekrar üretir (patlama yok); geri giden saat yeniden çıpalanır. Gecikme/aralık `NSEvent.keyRepeatDelay/Interval`'dan her oturum başında örneklenir (saçma değerde varsayılan 0.5 s / 83 ms).
  - Aynı Mac tuşuna iki kimlik (ör. scan 30 ve android 29) → tek down, son up'ta tek up.
  - **Bayat flags düzeltmesi (OwedRelease):** borçlu değiştirici up'ları slot sırasıyla tekrar oynatıldığı için üretimdeki flags yanlış olabiliyordu (son up hâlâ bir değiştiriciyi basılı gösterip flagsChanged ile yapışık flags bırakabilirdi; fuzz yakaladı). Tekrar oynatmada flags yeniden hesaplanır (`reflowModifierFlags`).
  - Gizlilik: yalnızca sayaçlar (`key_msgs`, `unknown_keys`, `repeats` → `input_session_end` satırı) ve bilinmeyen kimliğin numarası `debug` düzeyinde (`key_unknown`). Karakter/metin hiç loglanmaz.
- **Test edilmeyenler / cihazda doğrulanacaklar:** hiçbir CGEvent gönderilmedi. Doğrulanacak: (1) `isoKeyboardType = 41` ve ISO takası: Türkçe karakterler (ğüşıöç, `"`, `<`, AltGr+Q=@); (2) `flagsChanged` ile `CGEvent(keyboardEventSource:)` yapısı ve explicit flags'in uygulamalarda Cmd+C/V/Tab'ı doğru tetiklemesi; (3) `IOHIDSetModifierLockState`'in macOS 27'de ek izin isteyip istemediği ve Caps Lock'un gerçekten değişmesi (yoksa yedek: sentetik Caps flagsChanged); (4) sentetik tuşların tekrar üretimi (`keyboardEventAutorepeat=1`) ve tekrar hızı; (5) arka plana alınca basılı tuş kalmaması; (6) `--inject-test --keys "cmd+a,tab" --key-hold 1500` (yalnızca eklendi, çalıştırılmadı).
- **Açık sorular:**
  - Fare/kalem olaylarına değiştirici flags (Cmd+tık) eklenmedi; kapsam dışı sayıldı (MacMouse/MacTabletPoint imzası değişirdi). İstenirse ayrı kart.
  - Bir istemci UP'ı kaybeder ama bağlı kalırsa tuş sonsuza dek tekrarlar (protokol "her DOWN için UP" diyor; release-all/oturum sonu koruyor). Gerekirse tekrar için üst süre (ör. 30 s) eklenebilir.
  - `KeyMap` Android yedek tablosu yalnızca yaygın tuşları kapsar (harf, rakam, ok, F1-F12, keypad, değiştiriciler).

### Review turu 1 (Codex) düzeltmeleri

- **P1 bayat flags:** `OwedRelease.replay(..., keyboard:)` artık planner'ın o anki klavye durumunu (`KeyboardSnapshot`: basılı değiştiriciler + Caps) alır; tekrar oynatılan her bırakmanın flags'i ANLIK durumdan hesaplanır (basılı + hâlâ borçlu değiştirici up'ları), kayıtlı flags kullanılmaz (`reflowFlags`). Test: KFLAG-8 (Cmd up başarısız, Shift başarıyla bırakılır, tekrarda Cmd up flags boş), KFLAG-9, KPIPE-10.
- **P2 tekrar:** başka herhangi bir kimliğin DOWN'u (Caps ve eşlenmemiş tuş dahil) tekrarı durdurur; tekrar eden tuşun kendi yinelenen DOWN'u durdurmaz. Test: KFLAG-10.
- **Fare/kalem/kaydırma flags:** `MacMouse`, `MacTabletPoint`, `MacScroll` artık `flags` taşır; planner'da tek kural (`stampFlags`): her olay üretildiği anki klavye flags'ini (Caps dahil) alır, kapatan olaylar da; `releaseAll`'da işaretçi up'ları değiştirici up'lardan önce gelir, yani Shift'i görür. `CGEventFactory` her zaman açık `flags` atar (boş dahil), HID kaynağına güvenmez. Testler: KFLAG-1..7.
- Bilinen sınır: bir değiştirici up'ı başarısız olup borçluyken üretilen yeni KAPATAN olaylar (ör. Shift up) planner gölge durumu yüzünden borçlu değiştiriciyi flags'te göstermez; borçlu up tekrar oynatılınca durum düzelir, açan olaylar zaten engelli.
