---
id: T-033
title: Tablet klavye — fiziksel tuşları KEY olarak gönder, Android'e bırakma, sökülünce bırak
status: todo
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

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
