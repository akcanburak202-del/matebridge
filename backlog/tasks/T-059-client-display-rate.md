---
id: T-059
title: Tablet — panel hızını host'a bildir (DISPLAY_RATE)
status: review
phase: 5
owner: android-client-dev
depends_on: [T-057]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/protocol/
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/
  - backlog/tasks/T-059-client-display-rate.md
---

## Amaç

PROTOCOL `0x07 DISPLAY_RATE` (`proto/display-rate`, `87e36db`) istemci tarafı. Host T-058 seyreltmeyi yapar. Bu kart T-057'den sonra (aynı video dosyaları).

## Kabul kriterleri

- [ ] Kodek + fixture `display_rate`.
- [ ] Panel hızı (mevcut `display_hz` / vsync ölçümü) değişince: yükseliş hemen, düşüş ~0,5 sn kararlıysa; saniyede en çok 4 mesaj; `ACCEPTED`'dan sonra bir kez ilk değer.
- [ ] Sunum zamanlaması akış fps'i yerine gelen kare aralığına/panel hızına uyar; MediaCodec yeniden yaratılmaz.
- [ ] Testler (debounce, sıra). `./scripts/check.sh` (T-058 ile birlikte) geçiyor.

## Plan

1. Kodek: `DisplayRate(hz)` + `MsgType.DISPLAY_RATE=0x07`, fixture `display_rate` testi.
2. `stream/DisplayRateDebouncer` (saf): yükseliş hemen, düşüş 500 ms kararlıysa, en çok 4 mesaj/sn (250 ms aralık), ilk değer hemen.
3. Oturum: `SessionMachine.Event.SetDisplayRate`; ACCEPTED'da PING ve STREAM_PREFS'ten sonra bir kez (değer biliniyorsa), sonra yalnızca değişimde. `SessionController.setDisplayRate` tek-slotlu mailbox.
4. Panel hızı = vsync periyodundan yuvarlanmış Hz (`VsyncClock.periodNs`); MainActivity 100 ms'lik bir döngüyle debouncer'ı besler (yalnızca akış sırasında).
5. Sunum: `video/FrameInterval` (saf) etkin kare aralığı = varış aralığı panel periyoduna yakın/uzunsa max(akış aralığı, periyot), aksi halde akış aralığı (host seyreltmeden önceki geçiş). `ArrivalTracker` yakalama zamanlarından ölçer; Pacer'lar ve shown-listener kullanır; MediaCodec yeniden yaratılmaz.
6. Testler, check.sh, handoff.

## Handoff

- **Commit:** bkz. dal ucu (`task/T-059-client-display-rate`); `./scripts/check.sh`: Android gradle + fixture kontrolleri OK; tek FAIL `swift test (host-mac)` `everyFixtureFileHasATestCase` (`display_rate` host testi T-058'de; beklenen).
- **Dokunulan dosyalar:** `protocol/Messages.kt`, `Codec.kt` (DisplayRate 0x07); `session/SessionMachine.kt`, `SessionController.kt` (SetDisplayRate, mailbox); `stream/DisplayRateDebouncer.kt` (yeni); `video/FrameInterval.kt` (yeni: FrameInterval, ArrivalTracker), `FramePacer.kt`, `AdaptivePacer.kt` (`intervalProvider`), `VideoRenderer.kt`; `MainActivity.kt` (100 ms `rateTicker`); testler `DisplayRateTest`, `SessionMachineTest`, `FixtureTest`.
- **Varsayimlar:**
  - Panel hizi = `round(1e9 / vsync.periodNs)` (VsyncClock; epoch/panel-degisimi tespiti T-057'den). Debouncer: ilk deger ve yukselis hemen, dusus 500 ms kararli, en az 250 ms aralik (<=4/sn). Debouncer her `startVsync`'te yenilenir; makine ayni degeri tekrar gondermez ve ACCEPTED'da (PING, STREAM_PREFS'ten sonra) bilinen degeri bir kez yollar (yeniden baglanmada da).
  - Sunum: etkin aralik = gelen kare araligi (yakalama zamanlarinin EMA'si, >= 0.75 P ise) panel periyoduna yakin/uzunsa `max(akis araligi, P)`, degilse akis araligi (host henuz seyreltmedi: fazla kareler atilabilir yolu). Boylece 60 Hz panel + 120 fps akista host seyreltince pacer `surplus` yolundan cikip P kadansina gecer. MediaCodec yeniden yaratilmaz; `intervalProvider` calisma aninda okunur. 120 Hz panel davranisi degismez.
  - GL yolu (`GlPresenter`) dokunulmadi (vsync'e kendisi hizalar).
- **Test edilmeyenler / cihazda dogrulanacaklar:** hepsi. T-058 ile birlestirip: bosta (60 Hz) `MB/render ev=display_rate hz=60` ve host `cadence` yakalama/kodlama ~60; dokununca `hz=120`, hemen yukselis; dusus ~0,5 sn sonra; SF `--latency` 60 Hz bosta 33 ms bosluk %2-3'ten dusmeli; 120 Hz tekrar orani (~%3) bozulmamali; yeniden baglanmada ACCEPTED sonrasi bir `display_rate_sent`. `vsync.periodNs` panel degisiminde gec guncellenirse (reseed 4-12 ornek) bildirim o kadar gecikir.
- **Acik sorular:** yok.
