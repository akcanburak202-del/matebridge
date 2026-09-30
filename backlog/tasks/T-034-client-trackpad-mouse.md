---
id: T-034
title: Tablet trackpad ve fare — pointer capture, POINTER_REL, dokunarak tık, iki parmak kaydırma/sağ tık
status: review
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

1. `input/RelPointerTracker.kt` (saf Kotlin): touchpad hareket tanıma (`PadFrame`) + fare (`MouseFrame`) tek sınıfta, çünkü host `POINTER_REL`'i **tek kaynak** sayar ve düğme durumu tam/birleşik gitmelidir (touchpad | fare | dokunarak tık). Sabitler `PadTuning` nesnesinde.
2. Touchpad: parmak başına delta (id bazlı, sayı değişince zıplama yok); tek parmak -> ivmeli `POINTER_REL`, dokunuş eşiği (<=180 ms, az hareket) dolana kadar hareket biriktirilir (tık imleci kaydırmasın); iki parmak -> slop aşılınca `SCROLL` BEGAN/CHANGED, bırakınca ENDED; 2->1 veya >=3 parmakta tüm parmaklar kalkana kadar kilit. Fiziksel tık: 1 parmak LEFT, 2 parmak RIGHT (basış anında eşlenir); basılıyken en hızlı parmak sürükler. Dokunarak tık: 1 parmak LEFT, 2 parmak RIGHT (down+up).
3. Düğme kuralları (PROTOCOL 7): kapture/odak kaybında `release()` -> bildirilmiş düğmeler için `buttons=0`, açık kaydırma ENDED; sonra yalnızca yeni basış olayı (`pressedButton`) görülünce bildirilir; kaydırma canlılığı tick'te (200 ms CHANGED(0,0), 5 sn ENDED + park).
4. Fare: `AXIS_RELATIVE_X/Y` -> `POINTER_REL` (gain 1.0), tam düğme durumu, tekerlek -> `SCROLL phase=NONE` (1 çentik = 10 pt).
5. `InputCapture`: `onPad/onMouse/onPointerCaptureLost`, tick, releaseAll/forget/device removal entegrasyonu. `InputOutbox`: `POINTER_REL` birleştirme (aynı düğme durumu), sayaç `rel_msgs`; `taps`, `tp_scroll` sayaçları.
6. `MotionEventAdapter`: SOURCE_TOUCHPAD / SOURCE_MOUSE_RELATIVE olaylarını çerçeveye çevirir (touchscreen/stylus yolu değişmez). `MainActivity`: `videoView.requestPointerCapture()` (odak + oturum kabul + pencere odağı), `onPointerCaptureChanged(false)` -> release, captured listener.
7. Testler: `RelPointerTrackerTest` + `InputCaptureTest`/outbox ek testleri.

## Handoff

- **Commit:** (aşağıdaki commit; SHA orkestratöre raporda)
- **Dokunulan dosyalar:** `input/RelPointerTracker.kt` (yeni: touchpad + fare, `PadTuning`), `input/InputCapture.kt`, `input/InputOutbox.kt` (POINTER_REL birleştirme, `rel_msgs`), `input/Model.kt` (sayaçlar `rel_msgs`, `taps`, `tp_scroll`), `input/MotionEventAdapter.kt`, `MainActivity.kt`, testler `RelPointerTrackerTest.kt`, `RelPointerCaptureTest.kt`, bu kart.
- **Sabitler (`PadTuning`):** TAP_MS 180, SLOP_FRAC 0,02 (pad genişliğinin %2'si, tık ve kaydırma eşiği), SCREEN_SPAN 1,2 (pad genişliği = 1,2 Mac ekran genişliği), ivme GAIN_MIN 0,8 (<=150 pt/s) -> GAIN_MAX 2,6 (>=1800 pt/s) doğrusal, dt sıkıştırma 4..50 ms, SCROLL_GAIN 1,0, MOUSE_GAIN 1,0 (ivmesiz), WHEEL_NOTCH_PT 10, kaydırma canlılık 200 ms / boşta bitiş 5 sn, DEFAULT_EXTENT 1560 (aralık alınamazsa).
- **Varsayımlar:** (1) Pad x/y birimleri eşyönlü, ölçek yalnız X aralığından. (2) Captured olaylar pencere `dispatchGenericMotionEvent`'ine ve/veya odaktaki görünümün `OnCapturedPointerListener`'ine düşer: ikisi de `routeToCapture`'a bağlı (biri tüketirse diğeri görmez). (3) Touchpad fiziksel tık `BUTTON_PRESS`+`buttonState` ile gelir (NOTES); `actionButton` yeni basışı işaretler. (4) Tekerlek: `AXIS_VSCROLL>0` (yukarı) -> `dy=+10`, `AXIS_HSCROLL>0` -> `dx=-10` (host CGEvent'e olduğu gibi geçirir; yön hostta). (5) Host POINTER_REL'i tek kaynak saydığı için touchpad, fare ve dokunarak-tık tek birleşik düğme durumu üzerinden gider. (6) 2->1 veya >=3 parmakta imleç, tüm parmaklar kalkana kadar kilitli (zıplama yok). (7) Kaydırma/kapture kaybı `ENDED` ile kapanır (CANCELLED değil). Touchscreen/kalem capture dışıdır: Android captured olayları yalnız TOUCHPAD/MOUSE_RELATIVE kaynaklarından üretir; `MotionEventAdapter.handle` ekran/kalem dalı aynen duruyor, yeni dal yalnız `isCapturedPointer` için ve en üstte.
- **Test edilmeyenler / cihazda doğrulanacaklar:** pointer capture gerçekten alınıyor mu (`hasPointerCapture`, log `release_all`/`stats`), captured olayların hangi yoldan geldiği (Activity mi listener mı) ve `isFromSource` değerleri (TOUCHPAD 0x100008, fare MOUSE_RELATIVE); tek parmak imleç hissi ve ivme; dokunarak tık (tek = sol, iki = sağ, çift tık hostta clickState); fiziksel tık + sürükleme; iki parmak kaydırma yönü (host doğal kaydırma) ve hız; fare + tekerlek; arka plana/odak kaybına geçince düğme/kaydırma bırakılıyor mu, kalem ve parmak çizimi capture açıkken bozulmuyor mu; `MB/input` satırında `rel_msgs`, `taps`, `tp_scroll`.
- **Açık sorular:** Captured olay kaynağı sadece `TOUCHPAD` ise `SOURCE_MOUSE_RELATIVE` kontrolü gereksiz kalır, zararsız. Mouse captured olayları SOURCE_MOUSE (göreli eksensiz) gelirse işlenmez: cihazda doğrulanmalı. Sol tuş sahipliği (kalem önceliği) hostta.
