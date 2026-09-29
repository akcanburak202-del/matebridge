---
id: T-016
title: Görüntü akıcılığı — kare zamanlaması, 120 Hz, titreşim ölçümü
status: review
phase: 1
owner: android-client-dev
depends_on: [T-015]
decisions: [0004]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/video/
  - client-android/app/src/test/kotlin/dev/matebridge/client/stream/
---

## Amaç

İlk canlı testte (NOTES 2026-09-29) 56–59 fps'e rağmen kullanıcı "hafif takılma, ara ara fps düşüşü" gördü. Tablet 60 Hz'de ve kareler çözülür çözülmez çiziliyor. Hedef: hareketli içerikte gözle görülür takılma olmadan, gecikmeyi en fazla ~1 kare artırarak akıcı gösterim.

## Kabul kriterleri

- [x] **Ölçüm önce:** kare varış aralığı (network), çözme sonrası hazır olma aralığı ve ekrana gösterim aralığı için histogram/yüzdelik (p50/p95/p99, 16,7 ms'yi aşan aralık sayısı) saniyede bir `MB/render` loguna ve istatistik katmanına. Saf kısmı JVM testli.
- [x] **Yenileme hızı:** akış sırasında pencere için `preferredDisplayModeId`/`Surface.setFrameRate` ile 120 Hz (desteklenen en yakın) tercih edilir, akış bitince bırakılır. Seçilen mod loglanır.
- [x] **Kare zamanlaması:** `Choreographer` vsync'ine hizalı sunum. `releaseOutputBuffer(index, renderTimestampNs)` ile her kare bir sonraki uygun vsync'e planlanır. Küçük, ayarlanabilir bir titreşim tamponu (varsayılan 1 kare, en çok 2) ve "en yeni kare kazanır" kuralı korunur (§5). Tampon 0'a ayarlanabilir (şimdiki davranış), karşılaştırma için.
- [x] İstatistik katmanında seçili mod (60/120 Hz), tampon ve yukarıdaki yüzdelikler görünür.
- [x] `./scripts/check.sh` geçiyor.

## Notlar

- Orkestratör, Mac'teki 60 fps test sayfasıyla (Safari animasyonu) önce/sonra ölçümü yapar ve kullanıcıya gözle değerlendirtir.
- Gecikme hedefi: ölçülen uçtan uca gecikme (şu an ~39 ms) en fazla ~17 ms artmalı.

## Plan

- Saf mantık (JVM testli): `IntervalHistogram` (p50/p95/p99 + >16,7 ms sayısı), `VsyncClock` (Choreographer'dan vsync ızgarası + periyot kestirimi), `FramePacer` (kare başına render zamanı), `DisplayModePicker` (120 Hz'e en yakın mod).
- `VideoStats` üç histogram kazanır: ağ varışı, çözme sonrası hazır, ekranda gösterim (`MediaCodec.setOnFrameRenderedListener`).
- `VideoRenderer`: tampon 0 = eski davranış (en yeni kare hemen); tampon 1..2 = her kare `releaseOutputBuffer(idx, ns)` ile vsync ızgarasının orta noktasına (bir sonraki vsync'te gösterilir) planlanır, ardışık kareler içerik kadansında (60 fps içerik 120 Hz'de 2 vsync) ayrılır, birikim 1 içerik karesiyle sınırlı, aşınca yeni kare önceki slotu paylaşır (en yeni kazanır).
- `MainActivity`: Choreographer callback'i (onStart..onStop), akış sırasında `preferredDisplayModeId` + `Surface.setFrameRate`, akış bitince bırakılır; mod loglanır. Ayarlar başlatma extra'sı: `--ei jitter 0|1|2` (varsayılan 1), `--ei hz 120` (0 = dokunma).

## Handoff

- **Commit:** bkz. `git log task/T-016-video-smoothness`
- **Dokunulan dosyalar:** video/{IntervalHistogram,FramePacer}.kt (yeni), video/{VideoStats,FrameQueue,VideoRenderer}.kt, stream/{DisplayModePicker (yeni),StatsFormat}.kt, MainActivity.kt, test/.../video/PacingTest.kt
- **Varsayımlar (review düzeltmelerinden sonra):** Tampon N = "decode-ready + N vsync periyodu boşluğundan sonraki ilk vsync'te göster" (N vsync periyodu, içerik karesi değil). Toplam ek gecikme üst sınırı: N=1 için ~1 vsync periyodu + en çok yarım içerik karesi kadar kadans borcu (60 Hz'de <= ~25 ms, 120 Hz'de <= ~17 ms; tipik ~1 periyot). Borç yarım kareyi aşınca kare kendi decode-ready hedefine yeniden bağlanır; yalnız önceki karenin slotuna düşerse çarpışma sayılır. Codec'e verilen zaman V - periyot/2 (faz hatasına dayanıklı). `pace_add_ms` (saniyelik ortalama ek gecikme, en erken vsync'e göre) `MB/render ev=stats` içinde ve overlay'de. **`shown_` codec'in render zamanıdır (`setOnFrameRenderedListener`), SurfaceFlinger'ın gerçek present zamanı değil.** ">" eşiği 1,5 x vsync periyodu (`vsync_period_us` loglanır, overlay eşiği gösterir). Aynı drain'de aynı/önceki slota düşen eski buffer `render=false` ile bırakılır ve dropped sayılır (rendered değil). `Surface.setFrameRate` içerik fps'i (`config.fps`) ile çağrılır; 120 Hz isteği `preferredDisplayModeId` ile. Choreographer/DisplayListener yalnız akış sırasında; VsyncClock gerçek ekran hızıyla tohumlanır, 4 ardışık tutarlı uyumsuz aralıkta yeniden tohumlanır (60<->120), akış durunca sıfırlanır. Ayarlar yalnız intent extra'sı (kalıcı değil). Gösterim: `--ei jitter 0` eski davranış.
- **Test edilmeyenler / cihazda doğrulanacaklar:** Hiçbir Android yolu çalıştırılmadı. (1) `adb logcat -s 'MB/render'`: `ev=display_mode` (modlar listesi, seçilen id/Hz; HarmonyOS `preferredDisplayModeId`'yi dinliyor mu, `ev=stats` içinde `hz=`), akış bitince mod eski haline dönüyor mu. (2) Karşılaştırma: `adb shell am start -n dev.matebridge.client/.MainActivity --ei jitter 0 --ei hz 0` (eski davranış) ve `--ei jitter 1 --ei hz 120`, `--ei jitter 2`; `ev=stats` satırındaki `net_/ready_/shown_` p50/p95/p99/over ve overlay (uzun bas/F3). Shown aralığı p95/over düşmeli; `pace_add_ms` ~1 vsync periyodu civarında olmalı, uçtan uca gecikme artışı <= ~17 ms. 60->120 Hz geçişinde `vsync_period_us` ~8333'e oturuyor mu. (3) `releaseOutputBuffer(idx, ns)` bu HiSilicon codec'inde kareleri gerçekten zamanlıyor mu (shown aralığı tam vsync katları mı; değilse hepsi hemen çiziliyor demektir). (4) Kare kaybı (drop) tampon 1'de artıyor mu (çarpışma sayılır). (5) Home'a çıkıp dönünce mod geri/tekrar uygulanıyor, Choreographer durup başlıyor.
- **Cihaz sonuçları (orkestratör, 60 fps Safari animasyonu):** 120 Hz isteği seçiliyor (mod 1, 120 Hz) ama uygulanmıyor: uygulama vsync'i 16,67 ms'de kalıyor, `mActiveModeId=3` (60 Hz) sistem yenileme "High" iken de sürüyor; HarmonyOS FrameRateManager video uygulamalarını 60'a sınırlıyor gibi. `shown_over` her konfigürasyonda 5-15/s (A: j0 hz0, B: j1 hz120, C: j2 hz120, D: j1 hz0, E/F tekrar): tamponun ölçülebilir faydası yok. Kaynak fps ~57 (Mac kare atıyor, ayrıca incelenecek). Karar: varsayılan `jitter` = 0 (ek gecikme yok), 1/2 başlatma extra'sıyla seçilebilir; hz=120 isteği varsayılan kalır (zararsız).
- **Açık sorular:** HarmonyOS 60 Hz cap for video surfaces — try Surface.setFrameRate(120, FIXED_SOURCE) / vendor keys later. Faz (0,5) ve `MAX_SAMPLES`/eşik cihazda ayarlanmalı gerekirse. Ayrıca tampon kalıcı ayar istenirse `Settings.kt` kart kapsamına eklenmeli.
