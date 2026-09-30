---
id: T-038
title: Tablet — F tuşu olmayan klavye için yerel kısayollar (Ctrl+Shift+8/9/0)
status: todo
phase: 3
owner: android-client-dev
depends_on: [T-035]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/input/
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/input/
  - backlog/tasks/T-038-client-shortcuts-no-fkeys.md
---

## Amaç

Faz 3 cihaz testi (kullanıcı, 2026-09-30): yakınlaştırma, kaydırma ve `Ctrl+Shift+Esc` çalışıyor; ama Huawei Glide Keyboard'da **F tuşları yok**, bu yüzden `Ctrl+Shift+F1/F2/F3` (T-033/T-035) kullanılamıyor.

## Kabul kriterleri

- [ ] Aynı yerel eylemler rakam satırında da: `Ctrl+Shift+9` imleç yavaş (×0,85), `Ctrl+Shift+0` imleç hızlı (×1,15), `Ctrl+Shift+8` istatistik katmanı. Eşleşme **fiziksel konumla** (evdev scan code: 8 → 9, 9 → 10, 0 → 11), düzenden bağımsız. F1/F2/F3 kısayolları da kalır.
- [ ] Aynı `localOnly` mekanizması: rakam tuşunun DOWN/yinelenen DOWN/UP'u Mac'e gitmez; Ctrl ve Shift gider (bugünkü gibi).
- [ ] Oturum yokken rakamlar Android'e kalır (IP alanına yazılabilsin); yalnızca kısayol kombinasyonu yerel.
- [ ] Bağlantı panelindeki kısayol satırı güncellenir: "Ctrl+Shift+Esc: Android'e dön · Ctrl+Shift+9/0: imleç hızı · Ctrl+Shift+8: istatistik".
- [ ] Birim testleri: üç yeni kombinasyon, rakam tek başına ve yalnız Ctrl ile Mac'e gider, yinelenen DOWN yerel kalır. `./scripts/check.sh` geçiyor.

## Kapsam dışı

- Tel biçimi değişmez. Cihaz testi orkestratörde.

## Plan

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
