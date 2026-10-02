---
id: T-141
title: Durgun ekranda istemciyi uyutmak (vsync döngüleri, boş iş) ve normal kullanımda log azaltmak
status: review
phase: 5
owner: android-client-dev
depends_on: [T-140]
decisions: []
files:
  - client-android/app/src/
  - backlog/tasks/T-141-idle-power.md
---

## Amaç

Faz 0 ölçümü (docs/NOTES.md 2026-10-02 ~21:30 ve ~22:45): Mac ekranı durgunken (saniyede 0 kare) istemci tek çekirdeğin ~%20'sini yiyor, toplam sistem ~%70–80/800. Ana iş parçacığı oturum boyunca her vsync'te uyanıyor (`MainActivity.vsyncCallback`, GL yolunda `GlPresenter.frameCallback`). Bir anlık ölçümde de `HeapTaskDaemon` (GC) ~%10, `RenderThread` ~%5, `mb-ctl-read` ~%4,7 görüldü. Ayrıca `MB/decoder` ve `MB/render` saniyede birer uzun istatistik satırı yazıyor (logd ~%3). Hedef: durgun ekranda pil ve CPU tasarrufu, akış kalitesi ve gecikmesi değişmeden. Kullanıcı Faz 1'i onayladı (2026-10-02).

## Kapsam dışı

- Protokol, host, girdi yolu değişikliği. Yenileme hızı (T-140 olumsuz), oyun modu çözünürlüğü (ayrı konuşulacak).
- Ses yolu davranışı (AAudio/jitter); yalnız ölçülür, değiştirilmez.

## Kabul kriterleri

- [ ] **Önce döküm:** kod okuyarak durgun ekranda (oturum açık, kare gelmiyor) periyodik çalışan her şeyin listesi: Choreographer geri çağrıları, `ui.post/postDelayed` tikleri, iş parçacığı döngüleri ve yoklamalar, her tikte bellek ayıran yerler (GC kaynağı), View geçersiz kılmaları (`RenderThread`: istatistik kaplaması, `statsView.text` vb.). Plan bölümüne tablo olarak: ne, sıklık, durgunken gerekli mi.
- [ ] **Vsync döngüleri boşta durur:** son karenin üzerinden ~250–500 ms (gerekçeli sabit) geçince `vsyncCallback` ve GL `frameCallback` artık yeniden kaydolmaz. İlk yeni kare geldiğinde anında yeniden başlar. Yeniden başlamada vsync saati, faz kilidi ve `DisplayRateDebouncer` doğru tohumlanır. Durgunluk sonrası ilk kare bekletilmez, geç sunulmaz ve yanlış yuvaya düşmez: ilk kare gelir gelmez çizilebilir olmalı (gerekirse vsync tahmini yerine hemen sunum). Panel hızı ölçümü durgunken son değeri korur. DISPLAY_RATE durgunluk yüzünden yanlış değer göndermez (ör. hiç vsync yok diye 0 ya da 60).
- [ ] **Boş iş azaltılır:** dökümde "durgunken gereksiz" çıkan periyodik işler ya durgunken durur ya da seyrekleşir. Tik başına bellek ayırma (string birleştirme, liste/dizi kopyası, boxing) sıcak yollarda kaldırılır, ama yalnız ölçülebilir olanlar. Ses ve girdi iş parçacıklarına dokunulmaz, girdi ve ses gecikmesi değişmez.
- [ ] **Log:** `MB/decoder ev=stats` ve `MB/render ev=stats/present` varsayılanda 10 s'de bir (pencere 10 s, değerler o pencerenin özeti; biçim aynı, `interval_ms` doğru). `--ez stats_1s true` açılış parametresi eski 1 s davranışını geri getirir (teşhis için). Kare akmıyorken (pencerede 0 kare) bu satırlar yazılmaz, yerine yalnız durum değişiminde `render ev=idle state=on|off` yazılır. Olay satırları (`display_rate`, `keyframe`, hatalar vb.) değişmez. `docs/LOGGING.md` gerekiyorsa güncellenir (dosya kartın `files:` listesinde değil: gerekiyorsa *Açık sorular*a yaz, orkestratör yapar).
- [ ] Host'a giden istatistik mesajları (`controller.trySend(StatsFormat...)`) ve bunlara bağlı host davranışı (ör. gecikme/bitrate uyarlaması) değişmez. Hâlâ 1 s'de bir gidiyorlarsa öyle kalır.
- [ ] JVM testleri: boşta durma/yeniden başlama kararı (saf sınıf, saat enjekte), yeniden başlamada ilk karenin hemen sunulabilir olması, log penceresi toplama (10 s ve 1 s).
- [ ] `./scripts/check.sh` geçiyor.

## Ölçüm (orkestratör, cihazda; ajan yapmaz)

Aynı koşulda önce ve sonra: durgun ekran 2 dk (istemci CPU, iş parçacığı dökümü, panel Hz), ardından hareketli içerik ve oyun (fps, `skip_pct`, `latency_us`, `shown_p95`, durgunluktan sonraki ilk karenin gecikmesi). Kullanıcı takılma hissetmemeli.

## Plan

### Döküm: durgun ekranda (oturum açık, kare yok) periyodik çalışan işler

| # | Ne | Nerede / iş parçacığı | Sıklık (durgun) | Durgunken gerekli mi | Karar |
|---|----|------------------------|-----------------|----------------------|-------|
| 1 | `vsyncCallback`: `VsyncClock.onVsync` (her çağrıda yeni `Grid` nesnesi) + `vsyncGaps.mark` | MainActivity, ana | her vsync (60–120/s) + SF'nin uygulama vsync olayı | Hayır | **Uyur** (karesizlik ≥ 300 ms); ilk karede ya da işaretçi girdisinde uyanır |
| 2 | `GlPresenter.frameCallback` (yalnız `--es render gl`) | mb-gl | her vsync | Hayır | **Uyur** (aynı kapı); uyanınca bekleyen kare hemen çizilir |
| 3 | `rateTicker` (DISPLAY_RATE yoklaması) | ana | 100 ms | Hayır (period donuk) | vsync ile birlikte **durur**; uyanınca debouncer'ın düşüş adayı sıfırlanır, 5 taze vsync'ten önce rapor yok |
| 4 | `ticker`: keyframe yeniden deneme + `statsTick` (STATS mesajı, pacer `onSkipWindow`, A/V hedefi, katman, loglar) | ana | 500 ms / 1 s | STATS, pacer, A/V: evet (kart: değişmez). Loglar: hayır | STATS 1 s **kalır**. `decoder ev=stats`, `render ev=stats/present` **10 s pencere**, pencerede 0 kare varsa yazılmaz |
| 5 | Çözücü giriş döngüsü `awaitNext(4 ms)` | mb-decoder | ~250 uyanma/s | Hayır (yalnız kapanma süresini sınırlar; `offer` anında uyandırır) | ≥ 300 ms kare yoksa **20 ms** beklemeye çıkar (~50/s) |
| 6 | Çözücü çıkış döngüsü `dequeueOutputBuffer(5 ms)` | mb-decoder-out | ~200 uyanma/s | Hayır (çıkış anında döner; tutulan arabellek son anıyla zaten sınırlı) | ≥ 300 ms çıkış yoksa **20 ms** (~50/s) |
| 7 | `inputTicker` (`InputCapture.tick`, `syncInputActive`, işaretçi yakalama) | ana | 25 ms | Evet (girdi canlılığı/bekçiler) | Dokunulmadı (kart: girdi) |
| 8 | `autoTicker` (AUTO USB politikası) | ana | 500 ms | Evet (Wi-Fi→USB geçişi) | Dokunulmadı |
| 9 | `wolTicker` (WakePlanner, WolRefresh) | ana | 250 ms | Bağlıyken çoğunlukla boş | Dokunulmadı: ucuz, T-129/133/134 zamanlaması; ayrı ölçülmeli |
| 10 | `mb-session` motor tiki (PING 500 ms, PONG zaman aşımı, yeniden deneme) | mb-session | 100 ms | Evet | Dokunulmadı |
| 11 | `mb-stall` (StallDetector, T-120) + `diag ev=stall_stats` | mb-stall (URGENT_AUDIO) | 5 ms (200/s) + 1 s log | Yalnız teşhis (ses donmaları) | Dokunulmadı → *Açık sorular* (ayrı kart: açılış parametresine bağlamak) |
| 12 | Ses: `mb-ctl-read` AUDIO_PCM çözme, `mb-audio`, AAudio | mb-ctl-read, mb-audio | sürekli | Evet | Kart: dokunulmaz. Durgunda görülen GC'nin olası kaynağı (paket başına ayırma) — doğrulanmadı |
| 13 | `session ev=net` RTT satırı | ana (statsTick) | 1 s | Log | Dokunulmadı (kartta yok) → *Açık sorular* |
| 14 | `render ev=gl_stats` (yalnız GL deneyi) | ana | 1 s | Log | Dokunulmadı (deney yolu) |
| 15 | İstatistik katmanı `statsView.text` (açıksa) | ana → RenderThread | 1 s | Metin değişmiyorsa hayır | Metin aynıysa `setText` yok (RenderThread çizimi yok) |
| 16 | `statsTick` log dizeleri (~20 `String.format`, 3 satır) | ana | 1 s | Hayır | 10 s'de bir, durgunda hiç (ölçülebilir tek tik-başı ayırma) |
| 17 | PenOverlayView `postInvalidateOnAnimation` | ana/RenderThread | yalnız kalem/iz canlıyken | — | Zaten durgunda sessiz |
| 18 | `input ev=stats` | ana | 1 s, yalnız girdi varken | — | Zaten durgunda sessiz |
| 19 | RefreshVote (T-140) | ana | yalnız `--ei rvote` | — | Varsayılan kapalı |
| 20 | DisplayListener, OnFrameRendered (ana looper) | ana | olay / kare başına | — | Durgunda çalışmaz; listener kayıtlı kalır |

RenderThread ~%5 için kodda durgunda çizim tetikleyen tek aday katman metni (15); başka kaynak bulunmadı, cihazda bakılmalı.

### Uygulama

1. **`video/VsyncIdle.kt` (saf, saat dışarıdan):** `VsyncIdleGate` — `onActivity(now)` (her iş parçacığı; uyurken tam bir kez `true` = uyandırma gönder), `onVsync(now)` (döngü iş parçacığı; `false` = şimdi uyu), `wake(now)` (uyuyorsa uyandırır), `rateReady` (uyanıştan sonra ≥ 5 vsync), `idleLogDue(now)` (≥ 1 s uyuduysa bir kez `idle state=on`). Yarış: uyumaya geçerken etkinlik yeniden okunur (Dekker), kaçan kare olmaz. Ayrıca çözücü bekleme seçimi `IdleWait`.
   - **Eşik 300 ms (gerekçe):** ≥ 10 fps her akışta kareler arası ≤ 100 ms → akış asla uyumaz (3× pay); macOS imleç yanıp sönmesi (~0,5 s) arasında döngü uyuyabilir; son karenin çözme + yuva süresi (< 60 ms) eşiğin çok altında.
2. **MainActivity:** vsync döngüsü kapıya bağlanır. Uyurken `vsync.reset()` (faz unutulur, **period korunur** → panel hızı son değeri korur, DISPLAY_RATE gitmez), `vsyncGaps.breakSequence()`, `rateTicker` durur, `DisplayRateDebouncer.onPause()`. Kare (video okuyucu) ya da dokunma/kalem/işaretçi olayı kapıyı uyandırır: Choreographer + `rateTicker` yeniden başlar. **İlk kare:** saatte örnek yokken tüm pacer'lar `null` döner → çıkış hemen bırakılır (bekletme yok, eski fazdan yanlış yuva yok); ilk taze vsync'ten sonra normal zamanlama, faz kilidi > 3 periyot boşlukta zaten yeniden edinilir (T-065).
3. **GlPresenter:** aynı kapı GL iş parçacığında; uyurken frameCallback yeniden kaydolmaz, `glVsync.reset()`; `onFrameAvailable` uyurken kareyi hemen çizer ve döngüyü başlatır.
4. **VideoRenderer:** giriş/çıkış bekleme süreleri karesizlikte 4/5 ms → 20 ms (`IdleWait`); kapanma ≤ ~40 ms + codec (JOIN 300 ms içinde). `onSkipWindow` yalnız pacer + iz; `present` satırı ayrı `logPresent()`.
5. **Loglar:** `VideoStats` her 1 s pencereyi bir log penceresine ekler (toplamlar, ağırlıklı ortalamalar, histogram örnekleri taşınır → 10 s yüzdelikleri kesin). `IntervalHistogram.summaryInto()`. Saf `StatsLogWindow` pencere kapanışını ve "0 kare → yazma" kararını verir. Varsayılan 10 s; `--ez stats_1s true` → 1 s. Pencere `releaseRenderer`/`installConfig`'te kısmi olarak yazılır (oturum sonu verisi kaybolmaz). `render ev=idle state=on since_frame_ms=` (≥ 1 s uyuduktan sonra bir kez), `state=off idle_ms=` (yalnız `on` yazıldıysa).
6. **Testler (JVM):** kapı (uyuma, uyanma tek sefer, yarış, rateReady, log), uyanıştan sonra ilk karenin pacer'da hemen sunulması + ilk vsync'ten sonra gelecekteki yuva, debouncer `onPause`, `VideoStats` log penceresi 10 s / 1 s, `IntervalHistogram.summaryInto`, `StatsLogWindow`.

## Handoff

Durum: review. `./scripts/check.sh`: ALL OK.

- **Commit:** `4cf7c60` (uygulama), plan `372d15c`. Dal: `task/T-141-idle-power`.
- **Dokunulan dosyalar:**
  - yeni: `video/VsyncIdle.kt` (`VsyncIdleGate`, `IdleWait`), `stream/StatsLogWindow.kt`
  - değişen: `MainActivity.kt`, `video/GlPresenter.kt`, `video/VideoRenderer.kt`, `video/VideoStats.kt`, `video/IntervalHistogram.kt` (`summaryInto`), `stream/DisplayRateDebouncer.kt` (`onPause`)
  - testler: `test/.../video/VsyncIdleTest.kt`, `test/.../stream/StatsLogWindowTest.kt`
- **Varsayımlar:**
  - Durgunluk eşiği 300 ms (son *alınan* kareden). Gerekçe Plan'da ve `VsyncIdleGate` belgesinde.
  - Uyurken `VsyncClock.reset()`: faz unutulur, period korunur. Uyanıştan sonraki ilk kare(ler) ilk Choreographer çağrısına kadar pacer'dan geçmeden hemen bırakılır (`releaseOutputBuffer(idx, true)`). GL yolunda uyurken gelen kare `onFrameAvailable` içinde hemen çizilir.
  - **Kartta açıkça yazmayan ek:** dokunma/kalem/işaretçi olayı (`dispatchTouchEvent`/`dispatchGenericMotionEvent`) da döngüyü uyandırır. Dokunma paneli 120'ye çıkarır; döngü uyurken bunu ölçemezdik ve ilk hareket ~100 ms boyunca 60 fps'e seyreltilirdi. Olayın kendisi değişmez, girdi yoluna yalnız bir volatile yazma eklenir. Klavye uyandırmaz.
  - Uyanıştan sonra ilk 5 taze vsync gelmeden DISPLAY_RATE raporu yok. Debouncer'ın bekleyen düşüş adayı uyurken silinir; raporlanan değer korunur. Akış başlangıcındaki davranış değişmedi (ilk değer hemen gider).
  - Çözücü giriş/çıkış iş parçacıkları ≥ 300 ms kare/çıkış yokken 20 ms bekler (4/5 ms yerine). Kare ya da çıkış gelince anında uyanırlar. Bu yüzden durgunken `detachSurface` en çok ~40 ms daha uzun sürebilir (JOIN 300 ms içinde).
  - Log penceresi: `decoder ev=stats`, `render ev=stats`, `render ev=present` 10 s'de bir. Toplamlar, ağırlıklı ortalamalar ve histogram örnekleri 1 s pencerelerden aktarılır, yani yüzdelikler 10 s üzerinden kesin. `interval_ms` gerçek pencere uzunluğudur. `hz`, `vsync_period_us`, `buffer`, `pace_d_us`, `clock_offset_us`, `rtt_us`, `lead_ms`, `d_us`, `phase_lock` yazma anındaki değerdir (eskiden de öyleydi). Akış biterken ya da yeniden yapılandırılırken kısmi pencere yazılır (o ana kadar kapanmış saniyeler).
  - **0 kareli pencere iki modda da yazılmaz.** `--ez stats_1s true` de bu satırları durgunken yazmaz; yalnız pencere 1 s olur.
  - Yeni satırlar (`MB/render`): açılışta `ev=stats_log window_ms=10000|1000`. Döngü ≥ 1 s uyuduğunda bir kez `ev=idle state=on since_frame_ms=N` yazılır. Ardından uyanınca `ev=idle state=off idle_ms=N`. Daha kısa uyumalar (ör. imleç yanıp sönmesi) log yazmaz.
  - STATS mesajı, pacer `onSkipWindow`, A/V hedefi, katman yine 1 s. Katman metni değişmediyse `setText` çağrılmaz.
  - Bilerek açık bırakılanlar (Plan tablosu): `inputTicker` 25 ms (girdi), `autoTicker` 500 ms, `wolTicker` 250 ms, `mb-session` 100 ms, `mb-stall` 5 ms (aşağıda), ses iş parçacıkları, `session ev=net` ve `render ev=gl_stats` 1 s satırları.
- **Test edilmeyenler / cihazda doğrulanacaklar** (hiçbiri cihazda denenmedi):
  1. Durgun ekran 2 dk: `adb logcat -s 'MB/render:*'` ile ~1,3 s içinde `ev=idle state=on` gelmeli. Durgunken `decoder/render ev=stats` ve `present` satırı olmamalı. `top -H -p <pid>`: ana iş parçacığı neredeyse 0 olmalı, `mb-decoder` ve `mb-decoder-out` belirgin düşmeli. İstemci toplam CPU önce/sonra karşılaştırılmalı (önce ~%20). `dumpsys SurfaceFlinger`/`gfxinfo` ile uygulamanın vsync aboneliği kalkıyor mu bakılmalı. Kalan yük büyük olasılıkla `mb-stall` (200 uyanma/s) ve ses (`mb-ctl-read`, `mb-audio`, GC). Bunlar ayrı ayrı not edilmeli.
  2. Durgunluktan sonraki ilk kare: Mac'te tek bir değişiklik (ör. `sparse.py`/blinker, 2–5 s arayla), 12/12 doğru ve gecikmesiz görünmeli. Yazarken ilk tuş hemen gelmeli (T-062/T-065 senaryosu). Log'da `idle state=off idle_ms=` ardından gelen ilk `render ev=stats` penceresinde `skip_pct`/`shown_p95` normal olmalı.
  3. Panel/DISPLAY_RATE: durgunken `display_rate` satırı gelmemeli, özellikle 0 ya da yanlış 60 olmamalı. Durgunken ekrana dokununca (panel 120'ye çıkar) Mac'te hareket başlayınca `display_rate hz=120` gecikmeden gelmeli. Host `decimated=` 60'ta takılı kalmamalı.
  4. Hareketli içerik ve oyun (önce/sonra): fps, `skip_pct`, `latency_us`, `shown_p95`, `late_drops`. 10 s satırlarında `interval_ms` ≈ 10000 olmalı, `recv` ≈ 10 × fps. Kullanıcı takılma hissetmemeli. `--ez stats_1s true` ile eski 1 s satırları gelmeli.
  5. GL yolu (`--es render gl`): durgunluktan sonra ilk kare çiziliyor mu, `gl_draw_failed` yok mu.
  6. Akış bitince/arka planda `decoder ev=detach_slow` çıkmamalı (çözücü 20 ms bekleme).
- **Açık sorular:**
  - `docs/LOGGING.md` (kartın `files:` listesinde yok, orkestratör): `decoder ev=stats`, `render ev=stats/present` artık 10 s pencere (`--ez stats_1s true` → 1 s), 0 kareli pencere yazılmaz. Yeni satırlar: `render ev=stats_log window_ms=`, `render ev=idle state=on since_frame_ms=` / `state=off idle_ms=`. LOGGING.md:72'deki "Her 1 saniyede bir `ev=stats`" cümlesi güncellenmeli.
  - `mb-stall` (T-120 StallDetector): oturum boyunca URGENT_AUDIO önceliğinde 5 ms'de bir uyanıyor (200/s) ve saniyede bir `diag ev=stall_stats` yazıyor. Durgunda kalan en büyük periyodik uyanma kaynağı büyük olasılıkla bu. Ses teşhisi olduğu ve kart ses tarafına dokunmamayı söylediği için değiştirmedim. Öneri: ayrı kartta açılış parametresine bağlamak (`--ez stall_diag true`), varsayılan kapalı.
  - Saniyelik diğer satırlar `session ev=net`, `diag ev=stall_stats`, `audio ev=stats`, `render ev=gl_stats` kart kapsamında olmadığı için değişmedi. logd yükü için bunlar da 10 s'ye alınabilir; karar orkestratörün.
  - Durgunda görülen `HeapTaskDaemon` (~%10) için video tarafında ölçülebilir bir kaynak bulamadım. Durgunken vsync başına `Grid` ayırma ve saniyelik log dizeleri artık yok. Kalan aday ses alma yolu (paket başına çözme/ayırma); bu doğrulanmadı ve kart gereği dokunulmadı. RenderThread (~%5) için kodda tek aday katman metniydi, o da artık değişmiyorsa çizilmiyor.
