---
id: T-024
title: Tablet kalem ve dokunma yakalama — PEN toplu örnekler, POINTER_ABS, avuç reddi, RELEASE_ALL
status: review
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

- [x] **Kalem**: `onTouchEvent` + `onGenericMotionEvent` (hover) → bir `MotionEvent`'in tüm geçmiş örnekleri + güncel örnek tek PEN mesajında (en çok 64), `dt_us` azalmayan. Bayraklar: `IN_RANGE`, `CONTACT`, `STROKE_START` (yalnız `ACTION_DOWN` örneği), `BUTTON` (buttonState). `HOVER_EXIT` / `ACTION_CANCEL` → `flags=0` örnek. Silgi: `TOOL_TYPE_ERASER` → `tool=1`.
- [x] Eğim: §4 geçici dönüşüm (`tilt_x = sinθ·sinφ`, `tilt_y = −sinθ·cosφ`), temas sırasında son bilinen değer tekrarlanır. Basınç u16. Koordinatlar T-015'in `VideoViewport`'u ile normalize (tek yer).
- [x] **Menzil canlılığı**: `IN_RANGE` iken 100 ms'de bir yeni örnek yoksa son örnek güncel zamanla tekrar gönderilir.
- [x] **PEN_GESTURE**: M-Pencil çift dokunma (`keyCode 718 / scanCode 190`, iki kısa DOWN/UP) → tek `DOUBLE_TAP`; bu tuş olayları KEY olarak gitmez.
- [x] **Dokunma**: tek parmak → `POINTER_ABS source=TOUCH` (basılı = LEFT); iki parmak → `SCROLL` (BEGAN/CHANGED/ENDED, Mac nokta ölçeği `STREAM_CONFIG.width_pt`). **Avuç reddi / çizimde parmak kapalı** (karar 0006): kalem `IN_RANGE` iken ve son kalem örneğinden sonraki 1 sn boyunca yeni parmak basışları gönderilmez (bırakışlar her zaman gönderilir). Ayarlarda "Parmak dokunmasını tamamen kapat" seçeneği (varsayılan kapalı değil).
- [x] **RELEASE_ALL**: arka plan, odak kaybı, cihaz ayrılması; sonrasında kalem temasının ortası gönderilmez (§7).
- [x] **Tek sıralı FIFO** (§7): tüm girdi mesajları UI iş parçacığından, üretildiği sırayla T-012'nin sınırlı gönderim kuyruğuna; tıkanmada yalnızca hover örnekleri ve SCROLL CHANGED birleştirilir (§5).
- [x] Saf dönüşüm/toplama mantığı JVM testli (MotionEvent'ten bağımsız bir ara model üzerinden); fixture'larla bayt uyumu zaten T-009'da.
- [x] Loglama: `MB/input` saniyede bir özet (örnek/sn, mesaj/sn, avuç reddi sayısı); koordinat/karakter yok.
- [x] `./scripts/check.sh` geçiyor.

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

**Testler** (`test/.../input/`): PenTrackerTest, TouchTrackerTest, DoubleTapDetectorTest, InputOutboxTest, InputCaptureTest (sıralama + host referans modeli), InputFuzzTest (rastgele dizi + yaşam döngüsü + bağlantı kaybı), InputSupportTest (parmak ayarı varsayılanı, kuyruk tıkanıklık sinyali).

## Handoff

- **Commit:** dal `task/T-024-client-pen-capture`; uygulama `d89862b`, hata koruması `eeb7832`, jest logu `681b4b1`, ardından bu handoff commit'i (dal başı). `./scripts/check.sh` -> ALL OK.
- **Dokunulan dosyalar:**
  - Yeni `client/input/`: `Model.kt` (ara model, `InputSink`, sayaçlar), `PenTracker.kt`, `TouchTracker.kt`, `DoubleTapDetector.kt`, `InputOutbox.kt`, `InputCapture.kt`, `MotionEventAdapter.kt` (tek Android'e bağlı dosya, mantık yok).
  - `MainActivity.kt` (dispatch yönlendirmesi, yaşam döngüsü, ticker, cihaz dinleyicisi, ayar düğmesi), `session/SendQueue.kt` (`queuedBytes`/`oldestAgeMs`, `ControlLink.congested()`), `session/SessionController.kt` (`isSendCongested()`), `session/Settings.kt` (`fingerTouchDisabled`).
  - Testler `test/.../input/`: `PenTrackerTest`, `TouchTrackerTest`, `DoubleTapDetectorTest`, `InputOutboxTest`, `InputCaptureTest`, `InputFuzzTest`, `InputSupportTest`, `TestSupport` (host referans modeli + `FakeSink`). Protokol/codec/`VideoViewport` dosyalarına dokunulmadı.
- **Takılı girdi yolu -> test izlenebilirliği** (hepsi MotionEvent'ten bağımsız model üzerinde):
  - `ACTION_CANCEL`: `PenTrackerTest.actionCancelSendsFlagsZeroSample`, `TouchTrackerTest.actionCancelReleasesAPressedFingerAndCancelsAScroll`, `InputCaptureTest.actionCancelDuringAStrokeReleasesThePenOnTheHost`.
  - Odak kaybı: `InputCaptureTest.focusLossSendsTheNaturalReleasesThenReleaseAllAndSuspendsInput`, `...focusLossWithAPressedFingerReleasesItBeforeReleaseAll`, `...focusLossDuringATwoFingerScrollCancelsTheScroll`.
  - Arka plan: `InputCaptureTest.backgroundingReleasesEverythingBeforeTheSessionIsClosed` (RELEASE_ALL, BYE'dan önce kuyrukta), `...releaseAllIsSentEvenWhenNothingLooksHeld`.
  - Cihaz ayrılması: `InputCaptureTest.deviceRemovalReleasesOnlyDevicesWeWereReadingFrom`.
  - Gönderim kuyruğu tıkanması: `InputOutboxTest.releaseIsNeverMergedAndFlushesTheHeldMessageFirst`, `...releaseAllGoesOutBehindHeldDataNotAheadOfIt`, `...stateTransitionsAreSentImmediatelyEvenWhenCongested`, `InputCaptureTest.underBackpressureHoverIsMergedButTheReleaseIsNeverReorderedBehindIt`, `...underBackpressureStrokeSamplesAndTheirLiftAreNeverHeld`, `...underBackpressureScrollDeltasMergeButEndedAndReleaseAllAreNeverHeld`.
  - Kuyruk taşması / bağlantı kaybı / yeni oturum: `InputCaptureTest.aRefusedSendResetsTheModelAndTheStrokeMiddleStaysHoverAfterReconnect`, `...overflowDuringAStrokeResetsTheModelSoNothingIsSentAsAStrokeMiddle`, `...aNewControlConnectionForgetsTheModelSoAStrokeMiddleIsHover`, `InputOutboxTest.refusalDropsHeldDataAndReportsOnce`.
  - Vuruş ortası: `PenTrackerTest.strokeMiddleWithoutDownIsHoverOnly`, `...resetForgetsAContactSoTheMiddleOfThatStrokeIsHover`, `InputCaptureTest.afterAReleaseTheMiddleOfTheOldStrokeIsHoverOnlyAndTheNextStrokeStartsNormally`.
  - Menzil kaybı/tüm emniyetler: `PenTrackerTest.hoverWithoutFurtherEventsIsClosedAfterTheStaleWindow`, `...contactWithoutAnyEventIsClosedByTheLastResortGuard`, `...livenessRepeatsTheLastSampleEvery100msWithCurrentTime`, `TouchTrackerTest.restingFingersKeepTheHostScrollWatchdogAlive`.
  - Rastgele: `InputFuzzTest.*` (host referans modeli: her adımda host'un tuttuğu = istemcinin inandığı; sonda RELEASE_ALL göndermeden host boş; vuruş ortası ihlali yok). Kasıtlı bozma (mutasyon) denemeleriyle doğrulandı: UP/CANCEL/ENDED/flush-first/forget/STROKE_START/mid-stroke kurallarından biri bozulunca testler kırmızı oluyor.
- **Varsayımlar (PROTOCOL/karar 0006 yorumları):**
  1. Kalem `BUTTON` bayrağı kartın dediği gibi `buttonState` (STYLUS_PRIMARY|SECONDARY) ile eşlenir; karar 0006 (yan tuş yok) M-Pencil 3'te hiç set edilmeyeceği için zararsız, host bayrağı yok saymalı.
  2. `HOVER_EXIT` sonrası hemen `DOWN` geliyorsa (AOSP her vuruştan önce exit yollar) exit 40 ms bekletilir ve atılır; tek başına ise `flags=0` en geç ~65 ms sonra (tick 25 ms) gider. PROTOCOL "HOVER_EXIT -> flags=0" ifadesinden küçük bir gecikme sapması; her serbest bırakma/tick/sonraki kare gecikmiş exit'i mutlaka gönderir.
  3. `ACTION_UP` örneği `IN_RANGE` (temas yok) olarak gider, yani kalem hover'da kabul edilir. Sonrasında hover olayı gelmezse (hızlı kaldırma) hover 2 sn sonra `flags=0` ile kapanır (`hover_stale` sayacı).
  4. Temas 10 sn olaysız kalırsa son çare olarak `flags=0` gönderilir (Android UP/CANCEL garantisi bozulursa takılı kalmasın). Gerçek bir sabit basış 10 sn'den uzun sürerse vuruş kesilir (hover olarak devam eder).
  5. Eğim "son bilinen değer": eksen NaN ise veya temas sırasında tam (0,0) ise son geçerli değer tekrarlanır. Bu bir tahmindir (HarmonyOS seyrek güncellemeyi 0 ile mi yoksa eski değerle mi dolduruyor bilinmiyor); `tilt_held` sayacı bunu cihazda görünür kılar.
  6. Birleştirilebilir = yalnızca zaten gönderilmiş düz hover durumunu tekrarlayan hover PEN (temas/enter/leave/kaldırma sonrası ilk hover asla) ve SCROLL CHANGED. `POINTER_ABS` sürüklemeleri §5 listesinde olmadığı için birleştirilmez.
  7. Tıkanıklık = kuyrukta >= 8 KiB veya en eski mesaj >= 50 ms (sert sınır 256 KiB / 1 sn `SendQueue`'da aynen).
  8. RELEASE_ALL sırası: tutulan mesaj -> doğal bırakışlar (kalem `flags=0`, parmak UP, SCROLL CANCELLED) -> `RELEASE_ALL`. Arka plan/odak kaybı girdiyi `resume()`'a (pencere odağı geri gelince) kadar askıya alır; `DEVICE_DETACHED` askıya almaz. Video görünmez olunca (panel) `RELEASE_ALL(USER)` gider. Her zaman gönderilir, boş görünse de.
  9. Tek parmak: ilk DOWN 40 ms bekletilir (ikinci parmak tık üretmesin diye); kısa dokunuş DOWN+UP'u aynı konumda (tık, sürükleme değil) gönderir. Kalem menzile girince bekleyen/basılı tek parmak (avuç olabilir) bırakılır ve parmak kalkana kadar yok sayılır (karar 0006'ya ek, yalnızca bırakış üretir). Kaydırma sırasında kalem gelirse kaydırma sürer.
  10. İki parmak SCROLL: dx/dy = iki parmağın merkezinin hareketi x `width_pt/görüntü genişliği`, y `height_pt/görüntü yüksekliği`; 200 ms sessizlikte `CHANGED(0,0)` canlılık mesajı (host 500 ms watchdog'u hareketi bitirmesin). Zorla bırakmalar `CANCELLED`, doğal parmak kalkması `ENDED`. Host `CHANGED(0,0)` ve sıfır delta'lı BEGAN/ENDED'i sorunsuz kabul etmeli (T-022 için not).
  11. M-Pencil çift dokunma: 718 (veya key=0 + scan 190; F20'yi yutmamak için) iki DOWN <= 500 ms -> ikinci DOWN'da tek `PEN_GESTURE`; 400 ms kilit. Bu tuşlar `dispatchKeyEvent`'te tüketilir.
  12. Yalnızca `SOURCE_TOUCHSCREEN`/`SOURCE_STYLUS` olayları işlenir; klavye touchpad'i ve fare (source MOUSE/TOUCHPAD, ama tool FINGER görünebiliyor) sonraki trackpad görevine bırakıldı.
  13. Olay zamanı `eventTime*1000` (uptime = `System.nanoTime` ile aynı CLOCK_MONOTONIC), sentetik tekrarlar `now*1000`; mesajlar arası zaman geri gitmez (klemp).
  14. Codec `IllegalArgumentException` fırlatırsa (kendi hatamız) UI iş parçacığı çökmez: mesaj reddedilmiş sayılır, `RELEASE_ALL(USER)` denenir, model sıfırlanır (`invalid` sayacı). Girdi yolundaki beklenmedik `RuntimeException` da loglanır ve host'ta her şey bırakılır.
- **Log (`adb logcat -s MB/input`):** saniyede bir `ev=stats interval_ms= pen_samples= pen_msgs= touch_msgs= other_msgs= palm_reject= merged= refused= tilt_held= hover_stale= contact_stale= exit_absorbed= invalid=` (hareketsizse ve kalem menzilde değilse yazılmaz). Nadir olaylar: `input_active on=0|1`, `release_all reason= contact= pressed= scroll=`, `input_resume`, `session_reset`, `pen_gesture gesture=double_tap`, `input_error`. Koordinat/karakter yok.
- **Test edilmeyenler / cihazda doğrulanacaklar** (hiçbiri cihazda çalıştırılmadı; `MotionEventAdapter`, `MainActivity` yönlendirmesi ve panel düğmesi yalnızca derlendi):
  1. Kurulum + USB bağlantı, video gelince kalemi yaklaştır ve `adb logcat -s MB/input`: `pen_samples` hover'da ~330/sn civarı mı, `pen_msgs` 60-120/sn mi; `hover_stale` 0 kalmalı (Android HOVER_EXIT gönderiyor mu). Her vuruşta `exit_absorbed` artmalı (HOVER_EXIT -> DOWN sırası doğrulanır); artmıyorsa exit/DOWN arası 40 ms'den uzun.
  2. Vuruş çiz (Mac tarafı T-023 hazır olunca Krita): basınç, hover imleci, eğim işareti (kalibrasyon T-025); `tilt_held` temas sırasında artıyorsa (0,0) tutma tahmini devrede, çok artıyorsa eğim verisi gerçekten seyrek demektir.
  3. Vuruş sırasında Home'a bas -> `release_all reason=1 contact=1`, Mac'te basılı kalem yok; geri dön -> `input_resume`; kalemi aynı basılı vuruşta tutmaya devam edersen yeni bir çizgi başlamamalı (hover), kaldırıp tekrar basınca normal.
  4. Vuruş sırasında bildirim çubuğunu aşağı çek (odak kaybı) -> `release_all reason=2`, bırakınca `input_resume`.
  5. Vuruş sırasında Wi-Fi'yi kes veya USB kabloyu çek -> Mac'te basılı düğme kalmıyor; istemcide `refused` sayacı/`session_reset`; yeniden bağlanınca ilk temas örneği vuruş ortasıysa hover.
  6. Çift dokunma (M-Pencil) -> `pen_gesture gesture=double_tap` tek kez; Mac tarafında tek DOUBLE_TAP. (keyCode 718'in Activity'ye ulaşması T-003'te doğrulanmıştı.)
  7. Parmak: tek dokunuş = tık, sürükleme, iki parmak kaydırma (yön/hız Mac'te; delta Mac noktası). Kalem yakındayken (ve ~1 sn sonra) parmak basışları gitmiyor (`palm_reject` artıyor), avuç çizgiyi bozmuyor. Kaydırma sırasında parmaklar hareketsiz kalınca hareket 500 ms sonra bitmemeli (keepalive).
  8. Bağlantı panelindeki "Parmak dokunmasını tamamen kapat" düğmesi (Bağlan düğmelerinin altında, yalnızca bağlı değilken görünür): AÇIK yapınca parmak hiç gitmiyor, uygulamayı kapatıp açınca ayar korunuyor.
  9. Video üzerinde uzun basma ile istatistik katmanı artık çalışmaz (dokunma yakalanıyor); F3 tuşu ve panel düğmesi çalışır. Katman ihtiyacı için başka bir el hareketi gerekirse ayrı karar.
  10. Kalem+parmak birlikte, sanal ekran siyah bantlı olduğunda koordinat eşlemesi (imleç kalemin altında mı, kenarlar 0/65535'e oturuyor mu).
- **Açık sorular:**
  1. **Ayar için kalıcı arayüz:** "Parmak dokunmasını tamamen kapat" düğmesi düzen XML'i ve `strings.xml` kartın `files:` listesinde olmadığı için `MainActivity` içinde koddan panele eklendi (Türkçe metin Kotlin'de sabit). Ayar mantığı (`Settings.fingerTouchDisabled`) ve kalıcılığı hazır; istenirse düzen/metin kaynağına taşınacak, ya da Faz 5 ayar ekranında yer alacak.
  2. Video üzerinde uzun basmayla istatistik katmanı kaybı (yukarıda 9) için yeni bir hareket lazım mı?
  3. Host (T-022/T-023) için notlar: `SCROLL CHANGED(0,0)` canlılık mesajı ve zorla bırakmada `CANCELLED`; `PEN.BUTTON` yok sayılmalı; kalem ilk hover örneği (`flags=IN_RANGE`, enter) her zaman ayrı bir mesaj olarak gelir (birleştirilmez); `RELEASE_ALL(USER)` video/panel geçişinde de gelebilir.
  4. PROTOCOL §4 "menzil canlılığı" ile bu implementasyon: canlılık tekrarları 25 ms tick'e yuvarlandığından 100-125 ms aralıkla gider (host 500 ms watchdog için yeterli).
