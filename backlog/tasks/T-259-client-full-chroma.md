---
id: T-259
title: Client — packed full chroma (decision 0034): codecs, capability test, second decoder, ImageReader + GL merge path, pairing, prefs
status: review
phase: 6
owner: android-client-dev
depends_on: [T-257, T-252]
decisions: [0034, 0033, 0021]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/protocol/
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/main/cpp/
  - client-android/app/src/test/kotlin/dev/matebridge/client/
  - client-android/app/build.gradle.kts
  - docs/LOGGING.md
  - backlog/tasks/T-259-client-full-chroma.md
---

## Amaç

Karar 0034'ün istemci tarafı (panel hariç: T-260). Protokol `task/T-257-full-chroma-protocol` dalında; **bu dalın üzerine kur** (`git checkout -b task/T-259-client-full-chroma task/T-257-full-chroma-protocol`). Protokolü değiştirme.

## Bağlam

- **Codec (Kotlin):** `chroma_layout`, `view`, isteğe bağlı `KEYFRAME_REQUEST.view` (yalnız `chroma_layout = 1` iken yazılır), `chroma = 2`. Bütün fixture testleri.
- **Yetenek testi:** ilk kullanımda (ve APK güncellenince) kısa bir kendi kendine test: `GL_EXT_YUV_target` var mı, bilinen desenli küçük bir kareyi çözüp GPU'dan bit-tam okuyabiliyor mu (T-254 `t2` mantığı), ikinci `MediaCodec` açılabiliyor mu. Sonuç kalıcı saklanır; `FullChromaCapability` (panel T-260 bunu okur). Başarısızsa `chroma = 2` hiç gönderilmez.
- **Tercih:** kayıtlı "Renk" değeri (Normal/Keskin/Tam renk; T-260 taşıma yapar, burada okuma). `chroma = 2` yalnız Günlük + 60 fps + doğal ekran + SDR + yetenek varken; aksi halde `1` (Tam renk seçiliyse) ya da kayıtlı değer.
- **Video yolu:** `chroma_layout = 0` iken bugünkü doğrudan SurfaceView yolu **hiç değişmez**. `chroma_layout = 1` iken:
  - iki `MediaCodec` (ana + yardımcı), her biri `ImageReader` (PRIVATE, GPU örneklenebilir) çıkışlı; yardımcının ayrı sınırlı kuyruğu, `frame_seq` akış başına PTS.
  - Eşleme `capture_time_us` ile; GL iş parçacığı (T-254/T-256 native kodu ürün `cpp/` altına taşınır; `EXT_YUV_target`) ana + eşleşen yardımcıyı AVC444v2 ters eşlemesiyle birleştirir (T-255 düzeni; `pick`), RGB'ye çevirip aynı SurfaceView'ın EGL yüzeyine yazar. Yardımcı zamanında yoksa yalnız-ana (shader rengi büyütür).
  - **Sunum:** T-256 sonucu — duran kuyruk YOK: swap interval 0 + `eglPresentationTimeANDROID` slot hedefi ya da derinlik-1; `AdaptivePacer`/`SlotReleaser` slot mantığı korunur (hazır = ana hazır + GL geçişi). Yerleşim, ölçek ve girdi eşlemesi değişmez.
  - T-252 yetişme ana akışta aynen; yardımcıda newest-wins + `KEYFRAME_REQUEST(view=1)` (PROTOCOL §5).
  - Akış başına çözücü sağlığı; yardımcı hatası `video_health`'i düşürmez (ayrı sayaç), yardımcı yeniden kurulur.
- **Ölçüm (kabul şartı için):** `render ev=stats`'a `chroma_layout`, `aux_paired_pct`, `aux_late`, `gl_ms_p50/p95`; ekran gecikmesi bugünkü alanlarla (`latency_us`, `shown_*`) aynı tanımla iki yolda karşılaştırılabilir olmalı. `--ez dev true --ez full_chroma_direct true` gibi bir A/B düğmesi gerekmez: panelden Keskin ↔ Tam renk geçişi A/B'dir; ama aynı oturumda hızlı geçiş mümkün olmalı.
- Yeni bağımlılık ekleme (NDK/CMake zaten var, AAudio native modülü). Mac'te pencere açma; adb/tablet yok.

- **Oturum onayı (Codex T-257):** istemci `HELLO.capabilities` bit11 `FULL_CHROMA`'yı yalnız yetenek testi geçtiyse yazar.

## Kabul kriterleri

- [ ] Fixture testleri + birim testleri (eşleme, yalnız-ana geri düşüş, yardımcı kuyruğu, KEYFRAME_REQUEST view, tercih kuralları, yetenek saklama); `./scripts/check.sh` geçer.
- [ ] `chroma_layout = 0` yolunda davranış değişikliği yok (mevcut testler aynen).
- [ ] Handoff: cihaz kabul adımları — 0034 §9 durdurma kuralı ölçümü (aynı oturumda Keskin ↔ Tam renk: ekran gecikmesi p50/p95 farkı, `skip_pct`), `aux_paired_pct`, Wi-Fi ve USB.

## Plan

Dilimler (her biri JVM testli saf mantık + ince Android yapıştırıcı):

1. **Codec** (yapıldı): `StreamConfig.chromaLayout`, `VideoFrame.view`, `KeyframeRequest.view` (isteğe bağlı), `StreamPrefs.CHROMA_FULL`, `Capabilities.FULL_CHROMA`; 5 yeni fixture `FixtureTest`'te.
2. **Tercih/yetenek** (`stream/ColourChoice.kt`, `video/FullChromaCapability.kt`): `ColourChoice` (Normal/Keskin/Tam renk) okuma (`colour` anahtarı, yoksa eski `sharp_chroma`); `FullChromaPolicy.chromaRequest` (Günlük + 60 fps + doğal ekran + SDR + yetenek → 2, aksi halde Tam renk seçiliyse 1); `FullChromaCapability` kalıcı sonuç (APK sürüm anahtarlı; panel T-260 okur); `HELLO` bit11 yalnız geçtiyse (`SessionController` hello'ya çağrı anında OR'lanan sağlayıcı).
3. **Düzen matematiği** (`video/Avc444v2.kt`): ters eşleme (`sourceOf`), `YuvConversion` katsayıları; testte Swift `AVC444v2.pack`'in Kotlin kopyasıyla gidiş-dönüş bit-tamlığı. GLSL bu fonksiyonun satır satır çevirisidir.
4. **Yardımcı hat saf mantığı**: `AuxFrameQueue` (sınırlı, en yeni kazanır, CODEC_CONFIG saklanır, keyframe kapısı, `KEYFRAME_REQUEST(view=1)` hold-off), `AuxPairing` (son N yardımcı kare, `capture_time_us` ile eşleme, yalnız-ana geri düşüşü, `aux_paired_pct`/`aux_late`), `PackedStats` (gl_ms p50/p95).
5. **Native** (`cpp/mbfullchroma.cpp`, T-254/T-256 kodundan): EGL pencere yüzeyi (swap interval 0), AHardwareBuffer → EGLImage → `GL_EXT_YUV_target` dokuları, birleştirme/yalnız-ana programları, `eglPresentationTimeANDROID`, EGL zaman damgaları (present zamanı), GPU zamanlayıcı; pbuffer üstünde ham örnekleme karşılaştırması (yetenek testi).
6. **Sunucu** (`video/PackedPresenter.kt`, `AuxDecoder.kt`, `FullChromaPipeline.kt`): GL iş parçacığı (ana görüntü posta kutusu newest-wins, yardımcı halka, görüntüler bir çizim geç kapanır), ikinci `MediaCodec` + ImageReader, ana akış `VideoRenderer`'a küçük kanca: çıkış yüzeyi ana ImageReader'ın yüzeyi, `release` -> `releaseOutputBuffer(idx, true)` + `presenter.expect(pts, captureUs, renderNs)`; GL yolu ek öncü süre (`extraLeadNs`); gösterim zamanı EGL present zamanından `stats.onRenderCallback`'e. `chroma_layout = 0` yolu kancalar `null` iken değişmez.
7. **Bağlama** (`MainActivity`, `SessionController`): yapılandırma `isPacked444` ise boru hattı yeniden kurulur, aksi halde bugünkü yol; `view = 1` kareler boru hattına, tek akışta atılır; yardımcı hatası ayrı sayaç, yardımcı yeniden kurulur; GL başlatma hatasında yalnız-ana doğrudan yola düşülür (log).
8. **Yetenek testi** (`FullChromaSelfTest`): ilk kullanımda ve APK güncellenince arka planda: GL_EXT_YUV_target + ham örnekleme CPU ile bit-tam (gömülü küçük HEVC IDR, T-254 `t2` mantığı) + ikinci MediaCodec açılabiliyor mu; sonuç saklanır, başarısızsa `chroma = 2` ve bit11 hiç gönderilmez.
9. **Ölçüm**: `render ev=stats`'a `chroma_layout`, `aux_paired_pct`, `aux_late`, `gl_ms_p50/p95`; docs/LOGGING.md.

Kısıt: tablet/adb yok; GL ve MediaCodec yapıştırıcısı yalnız derleme + JVM testiyle doğrulanır, cihaz adımları Handoff'ta.

## Handoff

**Commit:** son commit `git log -1 task/T-259-client-full-chroma` (dal `task/T-257-full-chroma-protocol` üzerinde: 0b935ed plan + codec, e6b713b çekirdek, 27b425e bağlama, ardından "T-259: handoff" commit'i).

**Dosyalar:** `client-android/app/src/main/kotlin/dev/matebridge/client/`: `protocol/{Messages,Codec}.kt` (chromaLayout, view, KeyframeRequest.view, CHROMA_FULL, FULL_CHROMA); `stream/ColourChoice.kt` (Normal/Keskin/Tam renk okuma + `FullChromaPolicy`), `stream/GameMode.kt` (`prefs()` -> `chromaFor(mode)`); `video/`: `Avc444v2.kt` (ters düzen + `YuvConversion`), `AuxFrameQueue.kt`, `AuxPairing.kt` (+`GlTimings`), `AuxDecoder.kt`, `PackedPresenter.kt` (GL iş parçacığı), `FullChromaPipeline.kt` (+`FullChromaStatsFormat`), `FullChromaNative.kt` (JNI), `FullChromaCapability.kt`, `FullChromaSelfTest.kt` + `FullChromaSelfTestClip.kt` (gömülü 256x144 HEVC IDR, 5 KB, VideoToolbox ile üretildi), `VideoRenderer.kt` (küçük `PackedOutput` kancası); `session/SessionController.kt` (HELLO yetenek bitleri bağlantı anında); `MainActivity.kt`; `cpp/mbfullchroma.cpp` + `cpp/CMakeLists.txt`; `docs/LOGGING.md`; testler: `FixtureTest` (+5 fixture), `FullChromaCodecTest`, `Avc444v2Test`, `AuxQueueAndPairingTest`, `FullChromaPrefsTest`, `FullChromaSupportTest`, `PackedRendererTest`.

**check.sh:** `--only android` ve `--only protocol` geçer; tam çalıştırmada yalnız `swift test (host-mac)` düşer: `FixtureTests.everyFixtureFileHasATestCase` (Swift tarafı yeni 5 fixture'ı bilmiyor; T-258'in işi, bu dalın değişikliği değil).

**Tasarım özeti**
- `chroma_layout = 0`: `PackedOutput` kancası `null`, `renderer.packed == null`; `CodecSink`, renk anahtarları, dispatch öncüsü ve dinleyici aynı kod yolundan (mevcut renderer testleri aynen geçer). Yeni log alanları yalnız `render ev=stats` sonuna eklendi (`chroma_layout=0 ... -`).
- `chroma_layout = 1` (yalnız `fullChromaOn()` iken): ana akış `VideoRenderer`'ın kendi çözücüsü, çıkışı ana ImageReader (PRIVATE, GPU_SAMPLED); `release` -> `releaseOutputBuffer(idx, true)` + `PackedPresenter.expect(pts, captureUs, renderNs)` (hedef zaman eglPresentationTimeANDROID'e gider; ImageReader'a zaman damgalı release verilmez, damga görüntü zaman damgası olurdu). Yardımcı: `AuxDecoder` (ikinci MediaCodec, kendi `AuxFrameQueue` newest-wins/keyframe kapısı, `KEYFRAME_REQUEST(view=1)`), çıkış aux ImageReader. GL iş parçacığı: ana görüntü posta kutusu (newest wins), aux halkası (2), `capture_time_us` eşitliğiyle eşleme, yoksa yalnız-ana programı; swap interval 0 + `eglPresentationTimeANDROID`; görüntüler 50 ms sonra kapanır.
- GLSL birleştirme `Avc444v2.home` ile aynı ifadeler/sıra; Kotlin testi Swift `pack`'in kopyasıyla bit-tam gidiş-dönüş. Shader'ın kendisi cihaz dışında derlenemedi/koşulamadı (aşağıya bak).
- Aux hatası `video_health`'e hiç girmez; `AuxDecoder` kendi `RestartPolicy`'si (10 sn'de 3), sonra `aux_give_up` ve görüntü yalnız-ana sürer. GL kurulumu ya da 30 art arda çizim hatası -> `onFullChromaFailed`: süreç boyunca `chroma = 2` ve bit11 kapanır, STREAM_PREFS `chroma = 1` gider, ana görüntü doğrudan yola döner.
- Yetenek: `FullChromaSelfTest` (süreç başında, yapı başına bir kez, arka plan): `rawInit` (EGL + `GL_EXT_YUV_target`), gömülü IDR çöz -> YUV_420_888 ImageReader -> GPU ham okuma == CPU okuma (Y, Cb, Cr bit-tam), ikinci HEVC çözücü açılıp çıkış veriyor mu. Sonuç `full_chroma_cap` anahtarında `<sha>@<yapı zamanı>|pass|fail|retry`; panel (T-260) `FullChromaCapability.status()/available()` okur. HELLO bit11 `SessionController.helloCapabilities` ile her bağlantıda o anki durumdan eklenir.
- `colour` tercihi: `ColourStore` okur (`colour` anahtarı `normal|sharp|full`; yoksa eski `sharp_chroma`); yazan T-260.

**Varsayımlar / bilinmeyenler**
- **T-260 gelmeden Tam renk seçilemez** (panel yok). Cihazda denemek için `colour=full` değeri `matebridge` SharedPreferences'ına yazılmalı (debug yapıda `run-as dev.matebridge.client`) ya da T-260 beklenmeli.
- Gösterim zamanı: GL yolunda EGL `DISPLAY_PRESENT_TIME` (yoksa latch), doğrudan yolda codec'in frame-rendered geri çağrısı. İkisi arasında ~1 vsync tanım farkı olabilir; A/B'yi aynı oturumda Keskin <-> Tam renk geçişiyle `cap_cb_p50/p95` üzerinden okuyun.
- `extra_lead` (GL geçişi için slot öncüsüne eklenen) 4 ms sabit (`FullChromaPipeline.DEFAULT_EXTRA_LEAD_NS`); cihazda `gl_ms_p50` ve `skip_pct`'e göre ayarlanabilir (dev knob eklenmedi: docs/KNOBS.md kapsam dışı).
- Derinlik-1 kapısı uygulanmadı: swap interval 0 + presentation time yeterli sayıldı (T-256 `queue+swapint0` 0 atlama); `gl_outstanding_max` duran kuyruk belirtisini gösterir. Gerekirse eklenir.
- `ANativeWindow_setBuffersGeometry(w,h,0)` en iyi çaba; shader `vUv` ile eşlediği için boyut farkında da doğru (Günlük 2800x1840 ekrana tam oturur, fark beklenmez).
- Her `chroma_layout = 1` STREAM_CONFIG'te boru hattı baştan kurulur (aynı oturumda Keskin <-> Tam renk geçişi böyle çalışır; `detachSurface` en çok 300 ms UI'yi bekletir).
- İki ImageReader için `maxImages = 6`; `acquireNextImage` hataları `img_errors` olarak sayılır. AHardwareBuffer -> EGLImage önbelleği 16 girişle sınırlı (probtaki sınırsız önbellek yerine).

**Cihazda kontrol edilecekler (tablet oturumu, `adb logcat -s 'MB/*'`)**
1. Açılışta `render ev=full_chroma_selftest result=pass` (ve `full_chroma_selftest_detail ... exact=1 ... second_output=1`). `fail`/`inconclusive` ise nedeni `reason=`'da; fail kalıcıdır (yapı değişene kadar).
2. Tercihi `full` yapıp Günlük 60'ta: `render ev=full_chroma_start`, `gl_present_init frame_timestamps=1 gpu_timer=1`, `STREAM_CONFIG chroma_layout=1`; resim doğru renk ve yönde mi (ters/dikey çevrik ya da renk karışması shader hatasıdır), ince renkli yazı/ikon kenarları keskin mi; `render ev=stats`'ta `aux_paired_pct` (beklenen > %95), `aux_late`, `gl_ms_p50/p95` (~3 ms), `gl_outstanding_max` (<= 2), `aux_drop`, `aux_kf_req`.
3. **0034 §9 durdurma kuralı:** aynı oturumda Keskin <-> Tam renk geçişi; `cap_cb_p50/p95_us` farkı (<= +5 ms devam, > +10 ms kapat) ve `skip_pct` (bugünkünden kötü olmamalı); Wi-Fi ve USB'de.
4. 120 fps / Çizim / Oyun / HDR'ye geçiş: `chroma_layout=0`'a dönmeli (Tam renk seçiliyken `chroma = 1`), resim doğrudan yoldan; geri dönünce yeniden paketli.
5. Ekranı kapat/aç, uygulamayı arka plana al/ön plana getir: `surfaceDestroyed` temiz (GL ve iki çözücü durur), dönüşte görüntü gelir; `full_chroma_failed`/`aux_give_up` satırı olmamalı.

**TEST EDİLMEDİ (cihaz gerekir):** GLSL derlemesi ve doğruluğu, `GL_EXT_YUV_target` ham örneklemenin PRIVATE ImageReader'da bit-tamlığı (self-test YUV_420_888 ile karşılaştırır), ImageReader zaman damgası = frame_seq, EGL zaman damgaları, ikinci çözücünün ana akışla birlikte gecikmesi, dönüş/yaşam döngüsü, gerçek A/B gecikmesi.

## Open questions
- Protokol uyumsuzluğu bulunmadı. `KeyframeRequest.view`: istemci alanı `VIEW_UNSPECIFIED` iken yazmaz; ana akış isteğini `chroma_layout = 1` iken `view = 0` ile yazar (PROTOCOL.md ile uyumlu).
- Kapsam notu: dev knob (`--ez dev true ...`) eklenmedi; docs/KNOBS.md ve `DevKnobs` SPECS kaydı kart dosyaları dışında. Gerekirse orkestratör ister.
- host-mac `FixtureTests.everyFixtureFileHasATestCase` bu dalda düşer (Swift tarafı yeni fixture'ları kapsamıyor): T-258.

**Codex --high düzeltmeleri (aynı dal):** (1) self-test ImageReader dinleyicileri artık kendi HandlerThread looper kullanıyor (önceden null handler + Looper yok -> hep başarısız); harness istisnaları `Inconclusive` kalır, yetenek kaydı yapı anahtarlı. (2) `PackedPresenter.awaitPrevious`: önceki GL iş parçacığı çıkmadan yeni sunucu kurulmaz (1 sn sınırlı bekleme, sonra `full_chroma_gl_busy` ve doğrudan yola düşülür). (3) Her çizime GL fence (`glFenceSync`); görüntüler yalnız son kullanan çizimin fence sinyalinden sonra kapanır (`presentCompletedDraws`, güvenlik ağı 500 ms), 50 ms zamanlayıcı kalktı. (4) Yardımcı çözücü vazgeçince `active=false`, ingest ve aux keyframe isteği durur, boru hattı `onFailed("aux_give_up")` ile süreç için chroma=1 / doğrudan yola düşer; `AuxDecoderTest`. **Genel API değişikliği yok:** `FullChromaCapability`, `colour` anahtarı ve `ColourStore` aynı; yalnız `FullChromaNative.presentCompletedDraws` eklendi. check.sh --only android geçer; fence/looper davranışı cihazda doğrulanmadı.

**Codex tur 2 düzeltmeleri:** (1) self-test süreç çapında single-flight (ikinci çağıran bekler, kayıtlı sonucu görür). (2) Fence sinyali gelmeden görüntü asla kapanmaz; 500 ms dolunca `fence_stall` ile sunucu hata verir (chroma=1 / doğrudan yol), görüntüler teardown glFinish sonrası kapanır. (3) Zaman aşımına uğrayan teardown yüzeyleri (readers) elde tutar (`Leak`, `reap`); presenter çıkana dek doğrudan decoder yüzeye bağlanmaz (`attachDirect` erteler, ticker yeniden dener, `full_chroma_surface_busy`). (4) Eşzamanlı `start()` hatası artık `onFullChromaFailed` ile müzakereli chroma=1 yoluna gider. (5) Self-test: yalnız `GL_EXT_YUV_target` yok / ham örnek farkı / import hatası kesin fail; ikinci çözücü açılmaması-çıkışsızlığı, EGL init, no_ahb -> Inconclusive. (6) `AuxWatchdog` (2 sn girdi bekleme ya da >=3 kare çıkışsız) -> `aux_stalled`, RestartPolicy ile yeniden kurma/vazgeçme; `AuxWatchdogTest`. (7) Native: fence oluşturulamazsa glFinish + tamam girdisi, başarısız bekleme glFinish ile kuyruğu bitirir, en çok 8 fence (`fence_backlog` -> çizim reddi, 30 hatada yedek yol). API değişmedi (FullChromaCapability, colour anahtarı, ColourStore aynı; `PackedPresenter.shutdown/FullChromaPipeline.stop` Boolean döner). Cihazda denenmedi.

**Codex tur 3 düzeltmeleri:** (1) teardown sahipliği artık ana çözücünün tamamlanmasını da kontrol eder (`VideoRenderer.decoderThreadsFinished`, `GenerationHandoff.isIdle`); ana reader yalnız hepsi bitince kapanır. (2) `AuxDecoder` önceki codec çıkış iş parçacığı çıkmadan yeni codec kurmaz (`straggler`, sınırlı bekleme, sonra give-up); `isAlive()` iki iş parçacığını izler; watchdog codec nesli başına yerel. (3) Zaman aşımlı teardown listesi process çapında (`LeakList`), temizlik ana Looper üstünde kendi kendini yeniden planlayan reaper ile (Activity ticker'ından bağımsız, liste boşalınca durur). (4) `AuxWatchdog.onInput` `queueInputBuffer`'dan ÖNCE kaydedilir, hata olursa `onInputFailed` geri alır; yarış/rollback/nesil testleri ve `LeakList` testi eklendi. API değişmedi. Cihazda denenmedi.

**Codex tur 4 düzeltmeleri:** (1) `AuxDecoder.stop()` yalnız giriş iş parçacığı DEĞİL, çıkış straggler da bitince tamamlanır; aksi halde teardown reader'ı LeakList'te tutar (`AuxDecoderTest.stopIsNotCompleteWhileTheOutputThreadIsStuck`). (2) Ertelenmiş doğrudan bağlanma `detachVideoOutput`/`releaseRenderer`'da temizlenir, `config_id` ile kaydedilir; ticker yeniden denemesi yalnız aynı config_id, geçerli yüzey ve bağlı oturumda çalışır. API değişmedi.

**Codex tur 5 düzeltmeleri:** (1) `FullChromaPipeline.start`: iş parçacıkları ve reader'lar her başarılı ayırmadan hemen sonra alanlara yazılır; ikinci ayırma/thread başlatma düşerse `teardown()` birincisini kapatır. (2) `mbfullchroma.cpp` `pollTimestamps`: `eglGetFrameTimestampSupportedANDROID` ile init'te desteklenen damgalar belirlenir, yalnız onlar sorgulanır; DISPLAY_PRESENT yoksa (ya da geçersizse) latch zamanı gösterim zamanı yerine geçer, rendering-complete yoksa 0; latch desteklenmiyorsa damgalar kapatılır. (3) `PackedPresenter.run` biterken `previous` referansı kimlik korumalı temizlenir (`clearIfPrevious`; atama/temizleme senkron). API değişmedi. JVM testi eklenmedi (üçü de Android/EGL nesnesi ister); cihazda denenmedi: tabletle `gl_present_init frame_timestamps=1` ve `render ev=stats` gösterim zamanlarının hâlâ geldiğini doğrulayın.

### Codex integrated-review fixes (P2 x3)
- Runtime-off latch is now process-scoped (`FullChromaRuntime` in FullChromaCapability.kt), no longer an Activity field: survives Activity recreation; HELLO bit11 / chroma=2 stay off until app restart.
- Presenter/aux failure delivery is guarded by a run-generation token (`RunGeneration`, FullChromaPipeline): stale failures from a stopped run are ignored, including after the UI-thread post (`onFailed(why, stillCurrent)`); PackedPresenter also skips `onFailed` once `stopFlag` is set.
- PaceTrace.onRecv only for main (view 0) frames in SessionController; aux frames no longer overwrite seq-keyed main records.
- Tests: FullChromaRuntimeTest (latch, stale generation). check.sh ALL OK.
