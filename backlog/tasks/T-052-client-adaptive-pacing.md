---
id: T-052
title: Tablet — uyarlanır kare zamanlaması (en az gecikmeyle takılmasız sunum, 60/120 Hz)
status: todo
phase: 5
owner: android-client-dev
depends_on: [T-050]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/
  - backlog/tasks/T-052-client-adaptive-pacing.md
---

## Amaç

NOTES 2026-10-01 "Takılma ölçümü": Mac kareleri kusursuz 8,3 ms aralıkla gönderiyor; tablette sunumda vsync'lerin **%21'i atlanıyor** (iki kare aynı vsync'e düşüp sonra bir vsync boş kalıyor). `jitter=2` (2 karelik tampon) atlamayı %2'ye indiriyor ama +16,7 ms gecikme ekliyor; `jitter=1` (+8,35 ms) **hiç etkisiz** — büyük olasılıkla `FramePacer`/`drainOutput` mantığında hata. Kullanıcı hem düşük gecikme hem takılmasızlık istiyor; kalem kullanıyor.

## Kabul kriterleri

- [ ] **Neden analizi:** `jitter=1`'in neden etkisiz olduğu bulunur ve Handoff'ta açıklanır (ör. hedef zamanın vsync'e göre fazı, `releaseOutputBuffer(idx, ns)`'nin SurfaceFlinger'daki davranışı, aynı çekilişte (drain) iki kare, "collided" mantığı).
- [ ] **Uyarlanır zamanlama** (yeni varsayılan, surface ve GL yollarında): her kare, varış zamanlarının düzgünleştirilmiş fazına göre bir vsync'e atanır; ek bekleme `D` en az tutulur ve ölçülen atlama oranına göre ayarlanır (hedef: atlanan vsync < %2, `D` genelde ≤ 1 vsync; 60 ve 120 Hz'te çalışır; panel hızı değişince (60↔120, Huawei dokunma kuralı) yeniden kilitlenir). Birikme yok: sınırlı kuyruk, gecikince en yeni kare kazanır (AGENTS.md).
- [ ] **Ölçüm istatistikte:** `OnFrameRenderedListener` zamanlarından sunum aralığı histogramı → `MB/render` satırına `skip_pct` (1,5 vsync'ten uzun aralıklar, kare mevcutken), `pace_ms` (ortalama ek bekleme), `vsync_ms`. İstatistik katmanında da görünür.
- [ ] Eski `--ei jitter N` sabit tampon seçeneği deney için kalır; `--ei jitter -1` (ya da benzeri) uyarlanır modu kapatır.
- [ ] Saf zamanlama mantığı birim testli (sahte saat, vsync, dalgalanan çözme süreleri: atlama oranı ve ek gecikme sınırları). `./scripts/check.sh` geçiyor.

## Kapsam dışı

- Host. Cihaz ölçümü orkestratörde (`dumpsys SurfaceFlinger --latency`, scratch `pace.sh`).

## Plan

### Kök neden analizi (jitter=1 neden etkisiz)

`FramePacer.schedule`, hedef vsync'i `base = ilk vsync >= şimdi + N*P` ile seçiyor. Bu bir **tam sayı kaydırma**: `ceil(t + P) = ceil(t) + P`. Yani tampon N, karenin varış fazını vsync ızgarasına göre *hiç değiştirmiyor*; iki kare aynı vsync aralığına düşüyorsa (dalgalı çözme süresi) yine düşüyor, sadece hepsi N*P geç. Bu dalgalanmayı emen bir mekanizma yok.

Üstüne üç bozucu etki:
1. **Kadans mantığı 120 Hz'de ölü:** `fi == P` iken `v = max(base, last + P)`; `v - base` ızgaraya hizalı olduğu için 0 ya da >= P; `> fi/2` kuralı (P/2) her borç durumunu "çok borç" sayıp `v = base`'e geri sarıyor. Sonuç `v == base` (özdeşlik eşlemesi), çakışmada aynı slot.
2. **Zaman damgası ufkun içinde:** damga `V - P/2` ve `V - now` in [P, 2P) ise damganın şimdiye uzaklığı yalnızca [0,5P, 1,5P). SurfaceFlinger'ın (HarmonyOS/VRR) latch ufku genelde >= 1-2 vsync; ufuktan yakın damga "hemen sun" gibi davranır. Ölçüm bunu doğruluyor: jitter=0 (99/26) ile jitter=1 (98/27) birebir aynı, yalnızca `pace_add` 8,35 ms; jitter=2'de damga 1,5-2,5 P ileri -> damga gerçekten uygulanıyor ve 0 atlama.
3. Damga fazı (Choreographer app-vsync'i vs SF vsync'i arasındaki sabit kayma) bilinmiyor; `V - P/2` ancak bu kayma < P/2 ise doğru slotu verir.
Bu (2) ve (3) cihazda doğrulanamaz (bu oturumda tablete dokunulmuyor); (1) kod okumasıyla kesin.

### Çözüm: AdaptivePacer (video/AdaptivePacer.kt)

Host yakalama zamanı kusursuz düzenli (8,3 ms), varış/çözme çıkışı dalgalı. Bu yüzden playout gecikmesi yakalama zaman damgasına göre:
- `x = hazır_zamanı - captureUs*1000` (saat ofseti sabit, yalnızca fark önemli). Kayan 2 sn pencerede min `m` = en iyi durum hat gecikmesi; `dev = x - m >= 0` = o karenin fazla gecikmesi.
- `D = p98(son 256 dev) + 0,5 ms + extra`; `extra` = atlama oranına göre geri besleme (skip_pct > %2 -> +P/4, en çok 2P; 5 pencere < %0,5 -> -P/8).
- hedef = `hazır - dev + D` (yani `capture + m + D`, kare aralığı tam fi); slot = hedefi aşan ilk vsync (en erken şimdiki vsync); kare başına ayrı vsync (`slot >= son + P`); birikme `D + 2P`'yi aşarsa en yeni kazanır (çakışma, eski kare atılır).
- Damga `slot - P/2` (eski gibi). Panel hızı değişince (P %10+ değişirse) pencere, extra ve son slot sıfırlanır.
- Ölçüm: `PresentMeter`; `OnFrameRenderedListener` (pts -> hazır zamanı eşlemesi) aralıkları; aralık > 1,5 * kadans ve kare önceki gösterimden önce hazırsa "atlanan". `MB/render`: `skip_pct`, `pace_ms`, `vsync_ms`; overlay'de de.
- Modlar: `--ei jitter` yok -> uyarlanır (yüzey yolu); 0..2 sabit tampon (eski); -1 -> uyarlanır kapalı (=0). GL yolunda presenter kendi vsync hizalamasını yapıyor ve SurfaceTexture damgaları yok sayar; uyarlanır mod GL'de kapalı kalır (Açık soru).
- Testler: sahte saat/vsync, dalgalı hazır zamanları; 60/60, 120/120, 60 fps içerik 120 Hz; panel değişimi; PresentMeter; StatsFormat.


## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
