# Optimizasyon araştırması (T-330), 2026-10-10

Üç salt okuma Sonnet ajanı (kod + web; cihaz, adb ve derleme yok). Kod iddiaları orkestratör tarafından dosya okunarak doğrulandı. Sayıların çoğu **tahmin**; her madde A/B ile doğrulanmalı. Önceki tur: `2026-10-08-optimization.md` (tekrarlar çıkarıldı).

## Bağlam: Mac boşta (2026-10-10 00:36–00:41, tablet kapalı)

MateBridgeApp 5 dk'da 0,27 sn CPU (~%0,09), ~10 uyanma/s, 24 MB. VTEncoder boşta. Sanal ekran kaldırılmış. Uykuyu tutan assertion yok (`caffeinate` süreçleri Claude Code'un). Gereksiz yük yok.

## A. Boşta ve sabit ekranda enerji

Doğrulanan zamanlayıcılar:
- Host `SessionServer` 100 ms tik **bağlantı yokken de** çalışır (`SessionServer.swift:1634`). Boştaki ~10 uyanma/s'nin neredeyse tamamı budur.
- Host refine zamanlayıcısı 25 ms, oturum boyunca **sürekli** çalışır (`HEVCEncoder.swift:365`); refine açıkken 40 uyanma/s. Idle zamanlayıcı 250 ms.
- İstemci `inputTicker` 25 ms (`MainActivity.kt:1130`, `INPUT_TICK_MS`). Ekran sabitken de 40 uyanma/s, girdi tutulmasa bile.
- İstemci PING 500 ms (`WifiKnobs.kt:18`), PONG zaman aşımı 3 sn. Radyo derin uykuya giremiyor.
- İyi olanlar:
  - Statik ekranda kodlama yok: SCK `.idle` kareleri atılıyor, keepalive karesi yok.
  - İstemcide WakeLock ya da WifiLock yok. `KEEP_SCREEN_ON` kararınca bırakılıyor.
  - Arka planda oturum kapanıyor.

Öneriler:

| # | Değişiklik | Kazanç (tahmin) | Risk |
|---|---|---|---|
| A1 | İstemci: girdi tutulmuyorsa ve aktif işaretçi yoksa `inputTicker` 100 ms ya da olay güdümlü olsun; ilk MotionEvent hızlı tiki geri açsın. Bağlıyken wol/auto ticker kapalı. Ekran >2 sn sabitse PING 1000 ms. | ~50 uyanma/s + 1 radyo uyanması/s; T-320 pil testinin en büyük kolu | **Yüksek**: `capture.tick` ve `inputFailed` bırakma yolu. Girdi tutulurken yavaşlatılmaz. |
| A2 | Host: oturum tiki yalnız bağlantı varken (ya da en yakın son tarih için tek seferlik). WoL uzlaştırması ayrı 60 sn zamanlayıcıda. | Boşta ~10 → ~0 uyanma/s | Düşük: hello/proof zaman aşımları kabulde kurulmalı. |
| A3 | Host: refine zamanlayıcısı yalnız hareketli kareden sonra kurulur, tren bitince kapanır. Idle tik keyframe beklemiyorken 500 ms. | Bağlıyken ~40 + 2 uyanma/s | Düşük: refine başlangıcı en fazla bir periyot gecikir; girdiye etkisi yok. |
| A4 | Uzun oturumda bellek büyümesi: `tcpInfoSamplers`, `refinePairs`, `closingFiles`/`drainingLocals` kapanışta temizleniyor mu? | Doğrulanmadı | Bağlıyken 10 dk'da bir `ps -o rss` ile ölçülmeli. |

## B. Wi-Fi bit hızı verimliliği (Oyun 60 Mbps kuyruklanması)

Bugün:
- Kodlayıcı yalnız donanım "fast" profilini kullanıyor; LLRC kapalı.
- `DataRateLimits` 1 sn'lik pencerede ortalamanın 2× tavanı.
- QP sınırı ve `SpatialAdaptiveQPLevel` ayarlanmıyor.
- Fast profil, oturum ortasındaki QP/Quality/bit hızı değişikliklerini yok sayıyor (NOTES:570). Deneyler **oturum kurulurken** ayarlanmalı.
- Oyun 4:4:4 kullanmıyor (0034 yalnız Günlük 60). Ajanın "4:4:4'ü kapat" önerisi geçersiz.

| # | Kol | Beklenti | Risk ve ölçüm |
|---|---|---|---|
| B1 | Yalnız Oyun 60: LLRC (+ mümkünse `ConstantBitRate`). 60 fps'te 9–13 ms/kare bütçeye sığar. | Tepe kareler düzleşir; 30 Mbps temiz, 60 Mbps duruyor gözlemi ortalamanın değil **tepelerin** suçlu olduğunu düşündürüyor. 40–45 Mbps ≈ bugünkü 60 olabilir (spekülasyon). | Kodlama +3–7 ms. Önce EncodeBench'te aynı oyun kaydında kare boyutu p99/ortalama, sonra interleaved cihaz A/B. |
| B2 | `MATEBRIDGE_RATE_WINDOW_MS` (EN9, knob var) + oturum kurulurken `MaxAllowedFrameQP` | Sahne geçişinde tek kare şişmez; ortalama değişmez. | Kesmelerde bloklaşma. Kare bayt sütunu (HA1) ile maksimum kare + duraklama sayısı. |
| B3 | Keyframe tepeleri: IDR ort. 421 KB ≈ 3,4× P karesi. LTR kurtarma (HA4). | Önce `keyframe_request` nedenleri sayılmalı. | 2026-10-08'de zaten var; öncelik sayıma bağlı. |

Değmeyecekler: statik ekran zaten ~222 B'lık atlama kareleri üretiyor; H.264 (HEVC daha hızlı ve verimli).

## C. Tablette 60 fps çözme süresi

Yeni kaldıraç neredeyse yok. ADPF, sustained, vendor low-latency anahtarları, dilim/tile, H.264, LLRC ve SurfaceControl daha önce kapanmıştı.
- **C1 (önerilen):** T-320'yi uyarlamalı ve düşük görev oranlı yap.
  - Fling 2–3 sn'de bir (DDR tutma süresi ölçülsün).
  - Yalnız `dec_p50 > ~13 ms` ya da `skip_pct` yüksekken açık; Çizim 120'de ve dokunmada kapalı.
  - Not: kullanıcının Pil > Performans modu aynı kazancı kodsuz veriyor (ddr-clock Ek 2).
- **C2:** Huawei PerfGenius (HMS Accelerate Kit). Frekans isteği yaptığı belgelenmemiş. Yeni bağımlılık, karar kaydı ve HMS Core gerektirir; önce 30 dk'lık yalnız-probe. Düşük öncelik.
- **C3:** Bit hızını düşürmenin çözmeye etkisi küçük (−0,5–1 ms, tahmin). DVFS daha düşük saate inip kazancı silebilir.
- Ucuz ölçüm: Bluetooth trackpad/fare girişi DDR'ı yükseltiyor mu? Yükseltiyorsa gerçek kullanımda fling gereksiz.

## Sıralama ve kartlar

1. A2 + A3 (host, düşük risk) → **T-331**
2. A1 (istemci boşta zamanlayıcıları, yüksek risk; T-320 pil koluyla birlikte ölçülür) → **T-332**
3. B1 + B2 (Oyun kodlayıcı tepeleri; önce EncodeBench) → **T-333**
4. C1 → T-320 kartına not olarak eklendi.
