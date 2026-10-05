---
id: T-252
title: Client — on queue overflow, decode the backlog fast and show only the newest frame instead of flushing + keyframe request
status: review
phase: 6
owner: android-client-dev
depends_on: [T-251]
decisions: [0021]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/
  - client-android/app/src/test/kotlin/dev/matebridge/client/
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/DevKnobs.kt   # orchestrator extension: catch_up knob
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt         # orchestrator extension: one wiring line
  - docs/LOGGING.md                                                                  # orchestrator extension: ev=catch_up docs
  - backlog/tasks/T-252-client-catch-up-instead-of-flush.md
---

## Amaç

Bugün `FrameQueue` bekleyen kare sayısı sınırı aşınca (120 fps'te 8, `depthForFps`) tüm bekleyenleri atıyor, anahtar kare bekliyor ve KEYFRAME_REQUEST gönderiyor (`video/FrameQueue.kt` ~161–183). Anahtar kare büyük bir patlama: Wi-Fi'da ağı yeniden tıkıyor (T-121/T-122 "keyframe fırtınası"), görüntü IDR gelene kadar donuyor. T-248/T-249: çözücü 2800×1840'ta ~300–356 fps çözüyor (8 kare ≈ 25 ms), IDR karesi ~+15 ms. Kullanıcı onayladı (2026-10-05): "takılma sonrası hızlıca yetiş".

## Bağlam

- Yeni davranış (taslak; ajan kodu okuyup Plan'da kesinleştirir): kareler referans zinciri bozulmadan çözücüye verilmeye devam eder; sunum tarafı, yetişme sırasında yalnız en yeni hazır kareyi gösterir, eskileri `releaseOutputBuffer(render=false)` ile bırakır. Yetişme bitince pacer normal kilide döner (re-anchor; T-211/T-208 yapısı).
- Anahtar kare isteği yalnız gerçek bozulmada kalır (eksik kare / sıra boşluğu / çözücü hatası); salt birikme için istenmez. Birikme yetişemeyecek kadar büyürse (ör. > ~0,5 s ya da sınırlı bellek) bugünkü atma + istek yolu emniyet olarak kalır. Kuyruk sınırlı kalır (AGENTS.md: bounded queues).
- Ölçüm/tanı: `ev=catch_up frames= ms=` olayı ve `ev=stats` sayaçları (yetişme sayısı, atlanan sunum, istenmeyen IDR sayısı). Mevcut `overflows`, `kf_req` alanları korunur.
- Geri alma düğmesi: `--ez dev true --ez catch_up false` eski davranış (A/B için).
- Girdi tarafına dokunma. Tel biçimi değişmez.

## Kabul kriterleri

- [ ] Birikmede KEYFRAME_REQUEST gönderilmez; kareler çözülür, yalnız en yenisi gösterilir; birim testleri (FrameQueue/sunum karar mantığı) bunu kapsar.
- [ ] Emniyet sınırı aşılınca eski yol çalışır; testli.
- [ ] `./scripts/check.sh` geçer.
- [ ] Handoff: Wi-Fi ve USB'de cihaz doğrulama adımları (ör. Wi-Fi'da tam ekran geçişleri, `kf_req` ve donma süresinin karşılaştırması, `catch_up false` A/B).

## Plan

Tasarım: kareler çözücüye sırayla verilmeye devam eder (referans zinciri bozulmaz); yalnız *sunum* atlanır.

**FrameQueue (saf mantık, kilit altında):**
- `catchUpDepth` (0 = kapalı; renderer `CatchUp.depthForFps(fps)` = 0,5 s, en çok 64 kare) ve `catchUpMaxBytes` (32 MB). Normal yol: `pending > maxPending` iken `pending <= catchUpDepth` ve bayt sınırı içindeyse kare atılmaz, anahtar kare istenmez, `catchingUp=true` (episode başına `catchUps++`).
- Sınır aşılırsa (sayı ya da bayt) ya da catch-up kapalıysa bugünkü yol aynen: hepsini at, kapıyı kapat, KEYFRAME_REQUEST (T-121 hold-off dahil). Kuyruk her durumda `catchUpDepth` ile sınırlı (test: 500 kare).
- `awaitNext(..., mark)`: alınan kareye işaret verir (kilit altında, sahiplik kontrolüyle aynı adımda): `SKIP` = arkasında başka non-config kare var; `TAIL` = backlog'un en yenisi (kuyruk boşalırken alınan). Config kareleri hiç işaretlenmez ve backlog sayılmaz.
- Anahtar kare kapısı: `waitingKeyframe` iken P kareleri yine hiç kuyruğa girmez. Gelen anahtar kare eskileri atar (bugünkü kural) ve catch-up'ı bitirir; daha önce SKIP verilmiş kare varsa anahtar kare TAIL olur (hemen gösterilir, pacer yeniden demirler). `onDecoderError` / `reset` / `reconfigure` (reset(keepConfig=false)) catch-up durumunu ve verilmiş SKIP sayısını unutur; çözücü hatasında istek bugünkü gibi her zaman gider.
- Tüketici sahipliği (T-219): işaretleme `take()` içinde, `owns()` kontrolüyle aynı kilit adımında; emekli nesil hiçbir kare almaz, durum değiştirmez.

**VideoRenderer:**
- Giriş döngüsü işareti `CodecState.catchMarks` (pts -> işaret, sınırlı, en eski atılır) içine `queueInputBuffer` ÖNCESİ yazar; tutulan (`held`) kare işaretini de taşır.
- Çıkış (drainOutput): `SKIP` -> pacer'a, jitter geçmişine ve first-output bypass'ına dokunmadan `sink.discard` (render=false); `TAIL` -> `decision=null` yolu (anında göster, `flushAll` + `releaseNow`) ve `AdaptivePacer.reanchorAfterCatchUp()` + `FramePacer.reset()` (boşta-yeniden-demir ile aynı; backlog gecikmesi jitter sayılmaz, geri bildirim seviyesi korunur). İşaret yoksa (eski/evict) kare normal sunulur: en kötü durum eski davranış.
- Çözücü hatası: restart yeni `CodecState` (yeni işaret haritası) + `queue.resetIfOwner`; eski codec'in çıkış iş parçacığı yalnız kendi haritasına bakar.
- `catchUp` bayrağı (varsayılan açık) -> `catchUpDepth` (A/B). `ev=catch_up frames= ms=` ve `ev=stats` alanları `catchups= cu_skipped= kf_avoided=`; `overflows`, `kf_req` korunur.

**Kapsam notu:** `--ez catch_up false` bağlantısı `DevKnobs.kt` + `MainActivity.kt` gerektirir; ikisi `files:` listesinde yok. Renderer tarafı hazır (`VideoRenderer.catchUp`), bağlantı Open questions'ta.

**Testler:** `FrameQueueCatchUpTest` (işaretler, sınırlar, kapı, anahtar kare, hata, reset, sahiplik, sınırlılık), `CatchUpRendererTest` (gerçek renderer iş parçacıkları + sahte codec: sırayla çözülür, yalnız en yenisi render edilir, STARTUP dışında istek yok; kapalı/sınır üstü eski yol).

## Handoff

- Commit: `git log task/T-252-catch-up` (T-252 commit'i).
- Dosyalar: `video/CatchUp.kt` (yeni), `video/FrameQueue.kt`, `video/VideoRenderer.kt`, `video/AdaptivePacer.kt` (`reanchorAfterCatchUp`), `video/CodecGeneration.kt` (`catchMarks`); testler `FrameQueueCatchUpTest`, `CatchUpRendererTest`, `FakeDecoderCodec` (renderedPts/discardedPts).
- Varsayımlar: backlog sınırı 0,5 s / 64 kare / 32 MB, süre sınırı 300 ms, sunum aralığı 50 ms (`CatchUp.MAX_CATCH_UP_MS`, `SHOW_INTERVAL_MS`); eşik = bugünkü `maxPending` (120 fps'te 8); TAIL anında gösterilir (render zamanı 0 = bir sonraki vsync). Eksik kare / sıra boşluğu algılaması FrameQueue'da yok (oturum katmanında); dokunulmadı.
- check.sh: ALL OK (3 kez; knob + LOGGING eklemesinden sonra yeniden koşuldu, aşağıya bkz.).
- A/B: `adb shell am start ... --ez dev true --ez catch_up false` eski flush + keyframe yolunu verir.
- Test EDİLMEDİ (cihaz): Wi-Fi'da 120 fps tam ekran geçişi, gerçek çözücüde SKIP discard davranışı, TAIL sonrası pacer kilidinin geri gelmesi.
- Cihazda kontrol: (1) Wi-Fi'da `adb logcat -s MB:*` ile `ev=catch_up frames= ms=` satırları (ms ~ 25-60 beklenir), aynı pencerede `kf_req` artmaması, `ev=queue_overflow` yalnız >0,5 s birikmede; (2) görsel donma süresi eski yola göre kısa mı (A/B: `catch_up false`, bağlantı bekliyor); (3) catch-up sonrası `render ev=present` `skip_pct`/`lock` normale dönüyor mu; (4) USB'de aynı, `catchups=` çoğunlukla 0; (5) bağlantı kopma/uyku-uyanma sonrası görüntü normal.

- **Codex P1 düzeltmesi (sunum donması):** catch-up artık sınırlı. (1) Sürerken en geç her 50 ms'de bir kare `SHOW` işaretiyle hemen gösterilir (çıkışta TAIL gibi, pacer yeniden demirler; catch-up sürer). (2) Kuyruk normal derinliğe (`maxPending`) inince catch-up biter, sıradaki kare TAIL. (3) 300 ms içinde normal derinliğe inmezse (varış hızı >= çözme hızı) eski boşalt + KEYFRAME_REQUEST yolu çalışır. Testler: varış = çözme, varış > çözme, çözme > varış, derinliğe dönüş (`FrameQueueCatchUpTest`). check.sh ALL OK.

- **Codex tur 2:** (1) 300 ms süre sınırı artık `take()` içinde de denetlenir (varış olmasa da: burst + sessizlik + yavaş çözme); dolunca eski yol (boşalt, kapı, FRAMES_DROPPED; hold-off varsa bekletilir, periyodik retry yollar), istek `FrameQueue.onExpired` ile renderer'ın `onKeyframeRequest`'ine gider. (2) 50 ms'lik periyodik sunum kararı artık çıkış iş parçacığında, gerçek çıkış zamanıyla verilir (`CodecState.lastShowNs`; SKIP çıkışı son sunumdan >= 50 ms sonra geliyorsa gösterilir, pacer yeniden demirler); kuyruk yalnız SKIP/TAIL işaretler. Testler: burst-sonra-sessizlik, bekletilen istek, `CatchUpRendererTest.delayedOutputs...` (sahte codec çıkışları 20 ms aralıkla verir). check.sh ALL OK (3 kez).

- **Codex tur 3:** (1) Eşikler ayrıldı (orkestratör kararı): catch-up kuyruk boşalana kadar (arkada kare kalmayana dek) SKIP eder, TAIL = gerçekten en yeni kare (kalıcı gecikme yok); 300 ms süre sınırı (eski yol) yalnız o anda bekleyen > `maxPending` ise çalışır, `maxPending` altına inmiş birikim asla boşaltılmaz, en yeniye atlamaya devam eder (yanıp sönme 50 ms kuralıyla sınırlı). Test: `aBacklogDrainedToTheNormalDepth...`. (2) `cu_skipped` çıkış tarafında gerçek discard sayısıdır (50 ms kuralıyla gösterilenler sayılmaz). Testler güncellendi + `backBelowTheNormalDepthInsideTake...`. check.sh ALL OK.

- **Codex tur 4:** yeni catch-up bölümü her zaman kendi süre damgasını alır (eskiden `skippedOut == 0` ise); bir süre aşımından sonra kurtarma anahtar karesi + yeni burst eski damgayla boşaltılmaz. Test: `aNewEpisodeAfterAnExpiry...`. check.sh ALL OK.

## Open questions

- (Çözüldü) Orkestratör `DevKnobs.kt`, `MainActivity.kt` (tek satır) ve `docs/LOGGING.md` dosyalarını kapsama ekledi; `--ez catch_up false` (dev kapısı arkasında, `ev=profile knobs=` içinde `catch_up:0`) bağlandı, `DevKnobsTest` ve LOGGING.md güncellendi.
