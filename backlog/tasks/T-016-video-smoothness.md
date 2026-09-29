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
- **Varsayımlar:** Tampon içerik karesi cinsinden (60 fps için 16,7 ms), vsync'e yuvarlanır; varsayılan 1 => ~+1 kare gecikme beklenir. Slot vsync + 0,5 periyot (faz hatasına dayanıklı; sabit `phase`, cihazda ayarlanabilir). Gösterim aralığı `setOnFrameRenderedListener` nanoTime'ından (yaklaşık; SurfaceFlinger'ın gerçek present zamanı değil). Ayarlar yalnız intent extra'sı (kalıcı değil, `Settings.kt` dosya listesi dışı). Vsync periyodu ekran modu değişince `DisplayListener` ile güncellenir.
- **Test edilmeyenler / cihazda doğrulanacaklar:** Hiçbir Android yolu çalıştırılmadı. (1) `adb logcat -s 'MB/render'`: `ev=display_mode` (modlar listesi, seçilen id/Hz; HarmonyOS `preferredDisplayModeId`'yi dinliyor mu, `ev=stats` içinde `hz=`), akış bitince mod eski haline dönüyor mu. (2) Karşılaştırma: `adb shell am start -n dev.matebridge.client/.MainActivity --ei jitter 0 --ei hz 0` (eski davranış) ve `--ei jitter 1 --ei hz 120`, `--ei jitter 2`; `ev=stats` satırındaki `net_/ready_/shown_` p50/p95/p99/over ve overlay (uzun bas/F3). Shown aralığı p95/over düşmeli, gecikme <= ~+17 ms. (3) `releaseOutputBuffer(idx, ns)` bu HiSilicon codec'inde kareleri gerçekten zamanlıyor mu (shown aralığı tam vsync katları mı; değilse hepsi hemen çiziliyor demektir). (4) Kare kaybı (drop) tampon 1'de artıyor mu (çarpışma sayılır). (5) Home'a çıkıp dönünce mod geri/tekrar uygulanıyor, Choreographer durup başlıyor.
- **Açık sorular:** Faz (0,5) ve `MAX_SAMPLES`/eşik cihazda ayarlanmalı gerekirse. Ayrıca tampon kalıcı ayar istenirse `Settings.kt` kart kapsamına eklenmeli.
