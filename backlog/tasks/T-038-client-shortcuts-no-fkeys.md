---
id: T-038
title: Tablet — F tuşu olmayan klavye için yerel kısayollar (Ctrl+Shift+8/9/0)
status: done
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

1. `KeyTracker.localChord`: scan 9/10/11 (rakam 8/9/0) icin STATS/SPEED_DOWN/SPEED_UP eslemesi ekle (yalniz Ctrl+Shift ile); keyCode'a bakilmaz (duzenden bagimsiz).
2. Mevcut `localOnly` mekanizmasi aynen kullanilir; `InputCapture.onKey` degismez (oturum yokken rakamlar Android'de kalir).
3. MainActivity kisayol satirini guncelle.
4. KeyTrackerTest: 3 kombinasyon, rakam tek basina / yalniz Ctrl ile Mac'e gider, yinelenen DOWN yerel.

## Handoff

- **Commit:** (see branch head, task/T-038-client-shortcuts-no-fkeys)
- **Dokunulan dosyalar:** KeyTracker.kt, MainActivity.kt (kisayol satiri), KeyTrackerTest.kt, bu kart
- **Varsayımlar:** Eslesme yalniz scan code (9/10/11); scan code 0 gelen klavyede rakam kisayolu calismaz (F tuslari keyCode ile de eslesir). InputCapture degismedi: oturum yokken yalniz F3 yerel, rakamlar Android'de.
- **Test edilmeyenler / cihazda doğrulanacaklar:** Glide Keyboard'da Ctrl+Shift+9/0 imleç hizi, Ctrl+Shift+8 istatistik; rakamlar Mac'e sizmiyor; oturum yokken IP alanina rakam yazilabiliyor; panel satiri.
- **Açık sorular:**

## Orkestratör notu (merge, 2026-09-30)

- Küçük değişiklik, orkestratör okudu; `check.sh` ALL OK. Cihazda kullanıcı deneyecek.
