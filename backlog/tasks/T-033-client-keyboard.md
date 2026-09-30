---
id: T-033
title: Tablet klavye — fiziksel tuşları KEY olarak gönder, Android'e bırakma, sökülünce bırak
status: review
phase: 3
owner: android-client-dev
depends_on: [T-024]
decisions: [0003, 0008]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/input/
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/input/
  - backlog/tasks/T-033-client-keyboard.md
---

## Amaç

PROTOCOL.md §4 `0x11 KEY` istemci kuralları ve §7 istemci yükümlülükleri. Bugün `MainActivity.dispatchKeyEvent` yalnızca kalem çift dokunma tuşunu yakalıyor; diğer tuşlar Android'e gidiyor (F3 istatistik katmanını açıyor). Faz 0 ölçümleri: NOTES 2026-09-29 "Klavye (HUAWEI Glide Keyboard)".

## Kabul kriterleri

- [ ] Oturum girdi kabul ederken (mevcut `input_active` durumu) **fiziksel klavyeden** gelen her tuş olayı (`InputDevice` sanal değil, `SOURCE_KEYBOARD`) `KEY` mesajı olur: `scan_code`, `android_key_code`, `action`, `lock_state.CAPS_LOCK` (`metaState & META_CAPS_LOCK_ON`, olay sonrası durum). Tuş kimliği ikisi de 0 ise gönderilmez.
- [ ] Olaylar **tüketilir** (Android'e gitmez): Tab odak değiştirmez, Esc geri gitmez, Space/Enter butona basmaz. Esc'in ürettiği `KEYCODE_BACK` (scan 1) gönderilmez ve tüketilir (PROTOCOL). Android'in uygulamaya hiç vermediği sistem kısayolları (Home vb.) kapsam dışı; gözlenenleri Handoff'a yaz.
- [ ] `repeatCount > 0` olaylar gönderilmez (tüketilir). Kalem çift dokunma tuşu (718/190) bugünkü gibi `PEN_GESTURE`, asla KEY değil.
- [ ] **Basılı tuş takibi** (saf, testli sınıf, `input/` altında): gönderilen DOWN'lar cihaz + tuş kimliğiyle tutulur. Her DOWN'un bir UP'u gider. Takipte olmayan tuşun UP'u gönderilmez. Aynı tuşa ikinci DOWN (tekrar sayısı 0 olsa bile) gönderilmez.
- [ ] **Bırakma:** odak kaybı/arka plan/oturum sonu mevcut `RELEASE_ALL` yolundan geçer ve takip sıfırlanır; odak geri geldiğinde hâlâ basılı olan tuşun UP'u gönderilmez (host zaten bırakmış). **Klavye sökülünce** (`onInputDeviceRemoved`, klavye cihazı) o cihazın basılı tuşları için UP gönderilir (release-all gerekmez; diğer girdiler etkilenmez).
- [ ] Mesajlar tek sıralı FIFO'dan (mevcut `InputOutbox`) gider; KEY mesajları birleştirilmez/atılmaz.
- [ ] **İstatistik katmanı kısayolu:** F3 artık Mac'e gider. Yerel geçiş `Ctrl+Shift+F3` olur: bu kombinasyonda F3'ün DOWN/UP'u Mac'e **gönderilmez** (Ctrl/Shift gider; bu kabul). Oturum yokken düz F3 yerelde çalışmaya devam edebilir.
- [ ] **Gizlilik:** karakter/metin loglanmaz; tuş kimliği yalnızca debug. Sayaç: `key_msgs` mevcut `MB/input` istatistik satırına.
- [ ] Birim testleri: DOWN/UP eşleşmesi, tekrarların atılması, BACK/Esc, 718 filtresi, cihaz sökülünce UP'lar, release-all sonrası basılı tuşun UP'unun gönderilmemesi, Ctrl+Shift+F3. `./scripts/check.sh` geçiyor.

## Kapsam dışı

- Tel biçimi değişmez. Eşleme ve değiştirici tablosu host'ta (T-032).
- Trackpad/pointer capture (ayrı kart). Ekran klavyesi (IME) — gönderilmez.
- Cihaz testi orkestratörde.

## Plan

1. `input/KeyTracker.kt` (saf): `KeyFrame` (device, scan, keyCode, down, repeatCount, ctrl, shift, capsOn, timeUs) ve `KeyDecision(consumed, localToggle)`. Tuş kimliği = scan != 0 ? scan : 0x10000+keyCode. Basılı tuşlar (device, kimlik) -> (scan, keyCode) haritasında. BACK düşürülür+tüketilir; repeat>0 ve ikinci DOWN düşürülür+tüketilir; takipte olmayan UP gönderilmez+tüketilir; Ctrl+Shift+F3 DOWN yerel geçiş, gönderilmez. `releaseDevice(device)` UP'ları üretir, `reset()` takibi sıfırlar. `isPhysicalKeyboard(...)` saf yüklem.
2. `InputCapture.onKey(frame)`: yalnızca `accepting` iken KeyTracker'a gider, mesajlar mevcut `InputOutbox` üzerinden; accepting değilken düz F3/Ctrl+Shift+F3 yerel geçiş, diğerleri Android'e bırakılır. `releaseAll`/`forget` takibi sıfırlar (UP gönderilmez); `onDeviceRemoved` klavye cihazı için UP'ları gönderir (release-all yok). `key_msgs` sayacı (InputCounters + InputOutbox).
3. `MainActivity.dispatchKeyEvent`: pen jesti bugünkü gibi; fiziksel klavye olayları `capture.onKey`'e, tüketilir; F3 yerel geçişi `toggleStats`.
4. Testler: `KeyTrackerTest` + `InputCaptureTest` tarzı entegrasyon (host modeli yok, FakeSink).

## Handoff

- **Commit:** `git log task/T-033-client-keyboard` ("T-033: client keyboard KEY capture ...")
- **Dokunulan dosyalar:** `input/KeyTracker.kt` (yeni), `input/InputCapture.kt`, `input/Model.kt` (key_msgs), `input/InputOutbox.kt`, `MainActivity.kt`, `test/.../KeyTrackerTest.kt` (yeni), bu kart.
- **Varsayımlar:** Fiziksel klavye = `!isVirtual && source&SOURCE_KEYBOARD && keyboardType==ALPHABETIC` (karta ek: tabletin ses/güç tuşları KEY olmasın). Tüm `KEYCODE_BACK` (yalnız scan 1 değil) düşürülür ve tüketilir. Oturum yokken (input_active değil) F3/Ctrl+Shift+F3 yerel, diğer tuşlar Android'e gider (IP alanı yazılabilsin). Basılı F3'ün UP'u, arada Ctrl+Shift basılsa da gönderilir (takılmasın). `key_msgs` istatistik satırında `scroll_idle_end`'den sonra (mevcut testler satır sonuna bakıyor). Tuş kimliği hiç loglanmıyor.
- **Review turu 1 (Codex P2):** aynı tuş kimliği iki klavyede basılıysa DOWN yalnız ilk tutanda, UP yalnız son bırakanda/sökülende gider (cihaz bazlı takip korunur). Yerel tüketilen Ctrl+Shift+F3 basışı UP/sökülme/reset'e kadar izlenir; tekrar DOWN'ları ve UP'u yerel kalır. Testler eklendi.
- **Test edilmeyenler / cihazda doğrulanacaklar:** Gerçek Glide Keyboard'da `isVirtual` ve `keyboardType` değerleri (ALPHABETIC değilse hiç KEY gitmez; `MB/input` satırında key_msgs sıfır kalırsa ilk şüpheli); Tab/Esc/Space/Enter Android'e gitmiyor mu; Esc'in BACK'i uygulamadan çıkarmıyor mu; Ctrl+Shift+F3 istatistik katmanı, düz F3 Mac'e; klavye sökülünce basılı tuşun UP'u; arka plana geçince basılı tuşun Mac'te takılmaması. Android'in uygulamaya vermediği sistem kısayolları (Home vb.) gözlenmedi.
- **Açık sorular:** yok.
