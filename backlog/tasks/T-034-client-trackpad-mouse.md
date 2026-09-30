---
id: T-034
title: Tablet trackpad ve fare — pointer capture, POINTER_REL, dokunarak tık, iki parmak kaydırma/sağ tık
status: todo
phase: 3
owner: android-client-dev
depends_on: [T-033]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/input/
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/input/
  - backlog/tasks/T-034-client-trackpad-mouse.md
---

## Amaç

Glide Keyboard touchpad'i ve Bluetooth fare ile Mac imlecini kullanmak: PROTOCOL.md §4 `POINTER_REL`, `SCROLL` ve §7. Faz 0 ölçümü (NOTES 2026-09-29 "Trackpad"): normal modda kaydırma olayı yok, HarmonyOS iki parmağı dokunmatik sürüklemeye çeviriyor; **pointer capture** modunda touchpad `SOURCE_TOUCHPAD` (0x100008), ham mutlak parmak koordinatları (x ≈174–1734, y ≈97–1624), çoklu dokunma (POINTER_DOWN/UP), basınç sabit, relX/relY yok; fiziksel tık `BUTTON_PRESS`. Fare: `SOURCE_MOUSE`, hover olayları. Host tarafı hazır (T-022/T-023: `POINTER_REL` göreli hareket, düğme sahipliği, clickState, kaydırma fazları).

## Kabul kriterleri

- [ ] Oturum girdi kabul ederken ve pencere odaktayken video görünümü **pointer capture** ister; odak/oturum/kapture kaybında (`onPointerCaptureChange(false)`) basılı bildirilmiş düğmeler için `buttons = 0` gönderilir ve açık kaydırma `ENDED` ile kapanır (PROTOCOL §7 işaretçi kuralları). Kapture geri gelince yeni basış görülene kadar düğme bildirilmez. Dokunmatik ekran ve kalem capture'dan etkilenmez (mevcut yol aynen çalışır) — bunu kodda doğrula ve Handoff'a yaz.
- [ ] **Touchpad hareket tanıma** (saf, testli sınıf; girdi: zaman damgalı parmak listesi + düğme durumu; çıktı: protokol mesajları):
  - Tek parmak hareketi → `POINTER_REL` (Mac nokta). Ölçek: touchpad'in `InputDevice.getMotionRange(AXIS_X/Y)` aralığından; varsayılan olarak touchpad genişliği ≈ Mac ekran genişliğinin 1,2 katı, hıza bağlı basit ivme (yavaşta hassas, hızlıda uzun). Sabitler tek yerde, Handoff'ta.
  - Fiziksel tık (`BUTTON_PRIMARY`) → `LEFT`; basılıyken parmak hareketi sürükleme olur. İki parmak varken fiziksel tık → `RIGHT`.
  - **Dokunarak tık:** tek parmak kısa (≤180 ms) ve az hareketli (≤ eşik) dokunuş → LEFT down+up. İki parmak kısa dokunuş → RIGHT down+up.
  - İki parmak birlikte hareket → `SCROLL` BEGAN/CHANGED/ENDED (dx/dy = parmakların ortalama hareketi, Mac nokta, +y aşağı; yön/atalet host'ta). PROTOCOL SCROLL canlılık kuralları (200 ms'de bir sıfır `CHANGED`, 5 sn hareketsizlikte `ENDED`) mevcut dokunmatik kaydırma koduyla aynı şekilde.
  - Parmak sayısı değişince (1↔2) imleç zıplamaz; kaydırma temiz biter.
- [ ] **Fare** (`SOURCE_MOUSE`/`SOURCE_MOUSE_RELATIVE`, capture altında): `AXIS_RELATIVE_X/Y` → `POINTER_REL`; düğmeler (sol/sağ/orta/geri/ileri) tam durum; tekerlek (`AXIS_VSCROLL/HSCROLL`) → `SCROLL phase=NONE`, bir çentik = 10 pt (PROTOCOL).
- [ ] Mesajlar mevcut tek FIFO'dan (`InputOutbox`); `POINTER_REL` birleştirilebilir (dx/dy toplanır, düğme durumu değişen mesaj birleştirilmez), düğme değişimi hiçbir zaman atılmaz.
- [ ] Sayaçlar `MB/input` istatistik satırına: `rel_msgs`, `taps`, `tp_scroll`. Koordinat ya da hareket içeriği loglanmaz.
- [ ] Birim testleri: tek parmak hareket/ölçek, dokunarak tık ve iki parmak sağ tık, fiziksel tık + sürükleme, iki parmak kaydırma başla/sürdür/bitir, parmak sayısı değişimi, capture kaybında düğme bırakma ve kaydırma kapanışı, fare tekerleği. `./scripts/check.sh` geçiyor.

## Kapsam dışı

- Tel biçimi değişmez. Kaydırma yönü ("doğal kaydırma" ayarı) ve atalet host'ta; gerekirse ayrı host kartı.
- İki parmakla yakınlaştırma (pinch): ayrı kart (protokol değişikliği).
- Ayar arayüzü (hassasiyet, dokunarak tık açık/kapalı): Faz 4.
- Cihaz testi orkestratörde.

## Plan

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
