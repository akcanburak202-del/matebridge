---
id: T-024
title: Tablet kalem ve dokunma yakalama — PEN toplu örnekler, POINTER_ABS, avuç reddi, RELEASE_ALL
status: in-progress
phase: 2
owner: android-client-dev
depends_on: [T-015]
decisions: [0004, 0006]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/input/
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/
  - client-android/app/src/test/kotlin/dev/matebridge/client/input/
---

## Amaç

Tabletten Mac'e kalem ve dokunma: PROTOCOL.md §4 (PEN, POINTER_ABS, PEN_GESTURE, RELEASE_ALL) ve §7 istemci yükümlülükleri. Faz 0 ölçümleri: NOTES 2026-09-29 "Girdi probu sonuçları".

## Kabul kriterleri

- [ ] **Kalem**: `onTouchEvent` + `onGenericMotionEvent` (hover) → bir `MotionEvent`'in tüm geçmiş örnekleri + güncel örnek tek PEN mesajında (en çok 64), `dt_us` azalmayan. Bayraklar: `IN_RANGE`, `CONTACT`, `STROKE_START` (yalnız `ACTION_DOWN` örneği), `BUTTON` (buttonState). `HOVER_EXIT` / `ACTION_CANCEL` → `flags=0` örnek. Silgi: `TOOL_TYPE_ERASER` → `tool=1`.
- [ ] Eğim: §4 geçici dönüşüm (`tilt_x = sinθ·sinφ`, `tilt_y = −sinθ·cosφ`), temas sırasında son bilinen değer tekrarlanır. Basınç u16. Koordinatlar T-015'in `VideoViewport`'u ile normalize (tek yer).
- [ ] **Menzil canlılığı**: `IN_RANGE` iken 100 ms'de bir yeni örnek yoksa son örnek güncel zamanla tekrar gönderilir.
- [ ] **PEN_GESTURE**: M-Pencil çift dokunma (`keyCode 718 / scanCode 190`, iki kısa DOWN/UP) → tek `DOUBLE_TAP`; bu tuş olayları KEY olarak gitmez.
- [ ] **Dokunma**: tek parmak → `POINTER_ABS source=TOUCH` (basılı = LEFT); iki parmak → `SCROLL` (BEGAN/CHANGED/ENDED, Mac nokta ölçeği `STREAM_CONFIG.width_pt`). **Avuç reddi / çizimde parmak kapalı** (karar 0006): kalem `IN_RANGE` iken ve son kalem örneğinden sonraki 1 sn boyunca yeni parmak basışları gönderilmez (bırakışlar her zaman gönderilir). Ayarlarda "Parmak dokunmasını tamamen kapat" seçeneği (varsayılan kapalı değil).
- [ ] **RELEASE_ALL**: arka plan, odak kaybı, cihaz ayrılması; sonrasında kalem temasının ortası gönderilmez (§7).
- [ ] **Tek sıralı FIFO** (§7): tüm girdi mesajları UI iş parçacığından, üretildiği sırayla T-012'nin sınırlı gönderim kuyruğuna; tıkanmada yalnızca hover örnekleri ve SCROLL CHANGED birleştirilir (§5).
- [ ] Saf dönüşüm/toplama mantığı JVM testli (MotionEvent'ten bağımsız bir ara model üzerinden); fixture'larla bayt uyumu zaten T-009'da.
- [ ] Loglama: `MB/input` saniyede bir özet (örnek/sn, mesaj/sn, avuç reddi sayısı); koordinat/karakter yok.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

Mimari: MotionEvent'ten bağımsız saf çekirdek `input/` altında (JVM testli), ince Android bağlayıcı katman ayrı. Her şey UI iş parçacığında çalışır (§7 tek sıralı FIFO).

**Katmanlar**
1. `Model.kt`: ara model (`PenFrame`/`PenPoint`, `TouchFrame`, `Outgoing(msg, mergeable)`), `InputSink` (`send`, `congested`).
2. `PenTracker`: kalem durum makinesi OUT/HOVER/CONTACT. Tüm historical + güncel örnekler tek `PEN` mesajında (en çok 64, fazlası bölünür), `dt_us` azalmayan. `STROKE_START` yalnız `ACTION_DOWN`; DOWN olmadan gelen temas örneği (kilit sonrası vuruş ortası) hover olarak gider. CANCEL/HOVER_EXIT `flags=0`. Araç değişimi eski araç için `flags=0` sonra yeni araç. Eğim `Coords.penTilt`, temas sırasında geçersiz (NaN veya tam 0/0) eğimde son bilinen değer. Koordinat yalnızca `VideoViewport.normX/normY`. 100 ms canlılık tekrarı; hover 2 sn olay yoksa `flags=0` (HOVER_EXIT gelmeden kalem gitti), temas 10 sn olay yoksa `flags=0` (takılı kalma emniyeti). Android her vuruştan önce HOVER_EXIT gönderdiği için, HOVER_EXIT 40 ms geciktirilir ve hemen DOWN gelirse atılır (her vuruşta leave/enter dalgalanması olmasın); gecikmiş exit her serbest bırakmada/tick'te kesinlikle gönderilir.
3. `TouchTracker`: tek parmak `POINTER_ABS source=TOUCH` (LEFT), ilk DOWN 40 ms bekletilir (ikinci parmak gelirse tık üretmeden SCROLL'a geçilir; kıpırdama eşiği/bırakma/tick DOWN'u gönderir, DOWN gitti ise UP mutlaka gider). İki parmak `SCROLL` BEGAN/CHANGED/ENDED, Mac noktasına `width_pt/height_pt` ölçeğiyle, 200 ms'de bir CHANGED(0,0) canlılık (host 500 ms watchdog). Avuç kapısı: kalem `IN_RANGE` veya son kalem olayından 1 sn içinde yeni basış reddedilir (bırakışlar hep gider); kalem menzile girince bekleyen/aktif tek-parmak temas serbest bırakılır. "Parmak dokunmasını tamamen kapat" ayarı.
4. `DoubleTapDetector`: keyCode 718 (veya UNKNOWN + scanCode 190) iki DOWN <= 500 ms -> tek `PEN_GESTURE DOUBLE_TAP`; bu tuşlar tüketilir, KEY olarak gitmez.
5. `InputOutbox`: tek sıralı çıkış. Tıkanmada (sink.congested) yalnızca "mergeable" hover PEN ve SCROLL CHANGED kuyruk sonunda tutulup birleştirilir; başka her mesaj önce tutulanı boşaltır, sonra kendisi gider (sıra bozulmaz). Gönderim reddedilirse (oturum yok/taşma) model sıfırlanır: bağlantı düşüyor, host release-all uygular.
6. `InputCapture`: koordinatör. `releaseAll(reason)`: tutulanı boşalt, doğal bırakışlar (kalem `flags=0`, parmak UP, SCROLL ENDED/CANCELLED), sonra `RELEASE_ALL`; BACKGROUND/FOCUS_LOST askıya alır (`resume()` odak dönünce). Cihaz ayrılması, oturum başlangıcı, pasife geçiş yolları. Saniyelik `MB/input` özeti (sayaçlar; koordinat/karakter yok).
7. `MotionEventAdapter` (Android): MotionEvent -> ara model. Pointer başına araç tipi (STYLUS/ERASER/FINGER), historical örnekler, pencere->root koordinat kaydırması. MainActivity: `dispatchTouchEvent/GenericMotionEvent/KeyEvent` (yalnızca video görünürken ve viewport doluyken tüketir), `onPause`/odak kaybı/`InputDeviceListener`, 25 ms input ticker, `Settings`'e parmak kapatma ayarı, panelde kod ile eklenen anahtar düğmesi (layout XML kapsam dışı).
8. `session/`: `SendQueue` birikim ölçümü (bayt/en eski yaş), `ControlLink.congested()`, `SessionController.isSendCongested()`.

**İzlenebilirlik (takılı girdi yolu -> test)**: ACTION_CANCEL, odak kaybı, arka plan, cihaz ayrılması, gönderim kuyruğu tıkanması/taşması, oturum düşmesi, vuruş ortası devam, rastgele dizi + rastgele başarısızlık altında host referans modeli boşalıyor (fuzz). Adlı testler Handoff'ta listelenir.

**Testler** (`test/.../input/`): PenTrackerTest, TouchTrackerTest, DoubleTapDetectorTest, InputOutboxTest, InputCaptureTest (sıralama + fuzz + host referans modeli), SettingsTest (parmak ayarı varsayılanı).

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
