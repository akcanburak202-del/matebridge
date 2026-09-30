---
id: T-032
title: Mac klavye — KEY → macOS keycode, değiştiriciler, otomatik tekrar, Caps Lock, release-all
status: todo
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

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
