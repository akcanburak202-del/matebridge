# Kaynak profili: tablet ve Mac (T-282, 2026-10-06 akşam)

Kod değişikliği yok. Ölçüm, sıcak noktalar ve ölçülmüş kazancıyla aday listesi.

## Kurulum

- Taşıma **Wi-Fi** (adb de Wi-Fi'den, `adbd` %0). Host `build/` (main @ `1e65c99f`), tablet APK debug (debuggable, `lastUpdateTime 2026-10-06 19:28`).
- Senaryo başına 60 sn **temiz pencere** ve ardından 30 sn profil. Temiz pencerede tablette `/proc/<pid>/task/*/{stat,status}` önce/sonra farkı (iş parçacığı CPU %, bağlam değişimi/s, minor fault/s), `top -H -d 1` (30 örnek), `dumpsys meminfo`, logcat GC ve `MB/` satırları alındı. Mac'te `ps` CPU zamanı farkı ve pencereye düşen host.log alındı. Profil penceresinde tablette `simpleperf record --app -g -f 500` (30 sn), Mac'te `sample MateBridgeApp 10`. Profil araçları süreci yavaşlattığı için CPU yüzdeleri yalnız temiz pencereden alındı.
- Senaryolar:
  - **(a) boşta:** durağan masaüstü, ses yok;
  - **(b) video:** Safari YouTube 1080p60, sesli, tam ekran;
  - **(c) Oyun 60:** kullanıcı oynuyor, ses var;
  - **(d) yazı/kaydırma:** Günlük mod.
- Birim: **tek çekirdeğin yüzdesi** (100 = bir çekirdek; tablet 8 çekirdek).

**Uyarı (a):** "boşta" ölçümünde akış 0 değil, **~10 fps** idi. Kaynak Mac'te Terminal'deki Claude Code dönen simgesi ("Noodling…"). Ajan çalıştığı sürece ~10 fps'te kare üretiyor; iki `screencapture` farkıyla doğrulandı, değişen bölge yalnız Terminal penceresi. Gerçek durağan ekran (0 fps) değerleri T-141/T-142'de ölçüldü: istemci ~%7–10. Buradaki (a) satırı "10 fps arka plan" anlamına gelir.

## Özet tablo: tablet

| | (a) 10 fps | (b) video 60 | (c) oyun 60 | (d) yazı ~20 fps |
|---|---:|---:|---:|---:|
| **İstemci toplam** | **23,8** | **106,4** | **107,6** | **47,3** |
| `mb-audio` | 2,2 | **38,8** | **33,6** | 2,7 |
| `HeapTaskDaemon` (GC) | 0,1 | 5,4 | **14,0** | 3,1 |
| `mb-video` (alma + şifre çözme) | 0,6 | 7,4 | **13,0** | 5,0 |
| ana iş parçacığı | 6,2 | 8,5 | 10,2 | 10,9 |
| `MediaCodec_loop` | 4,6 | 11,3 | 9,0 | 6,2 |
| `CodecLooper` | 2,0 | 9,1 | 7,7 | 4,5 |
| `mb-decoder-out` | 3,7 | 8,3 | 6,5 | 4,8 |
| `mb-decoder` | 2,0 | 5,7 | 4,0 | 2,8 |
| `mb-ctl-read` | 0,2 | 5,1 | 2,6 | 0,3 |
| minor fault/s | 100 | 2 230 | **7 042** | 1 349 |
| surfaceflinger | 6,9 | 15,2 | 11,3 | 10,7 |
| media.codec HAL | 3,1 | 12,9 | 13,5 | 7,1 |
| sistem toplamı (/800) | 52 | 137 | 153 | 93 |

Uyanma (gönüllü bağlam değişimi/s), (a) 10 fps'te: `MediaCodec_loop` 453, `mb-decoder` 265, `mb-decoder-out` 246, `mb-audio` 200, ana 122. (c) 60 fps'te: `MediaCodec_loop` 798, `mb-decoder-out` 513, `mb-decoder` 390, `mb-video` 290, `CodecLooper` 298, `mb-audio` 205.

## Özet tablo: Mac (`ps` CPU zamanı farkı)

| | (a) | (b) | (c) | (d) |
|---|---:|---:|---:|---:|
| MateBridgeApp | 5,2 | 15,0 | 14,0 | 21,2 |
| VTEncoderXPCService | 0,6 | 3,0 | 2,1 | 1,7 |
| WindowServer | 4,8 | 14,0 | 13,0 | 21,9 |
| coreaudiod / replayd | 1,6 / 0,9 | 2,3 / 2,3 | 2,7 / 2,4 | 1,6 / 1,8 |

MateBridgeApp 65–109 MB RSS. `sample` çıktısında tek baskın sıcak nokta yok. Meşgul örnekler kuyruklara dağılmış: ses kuyruğu ve IOThread, oturum, kodlayıcı geri çağırması, yakalama, girdi. Hiçbir kalem tek başına %2'yi geçmiyor. WindowServer payı sanal ekran ve SCK'nin doğal bedeli. **Mac'te kart yok.**

## Sıcak noktalar (simpleperf, tablet)

1. **Ses yeniden örnekleyici yorumlayıcıda çalışıyor.** (b)'de `mb-audio` örneklerinin %93'ü `CubicResampler.process` içinde. Bunun **%51'i `kotlin.math.roundToInt`** çağrısı; örnek ve kanal başına bir kez, yani 96 000/s. Yığında `artQuickToInterpreterBridge`, `MterpInvokeStatic`, `DoCall`, `Jit::IgnoreSamplesForMethod` var: çağrı JIT kodundan yorumlayıcıya düşüyor. Neden JIT'lenmediği belirsiz. [Tahmin: debuggable çalışma zamanının etkisi.] Ses yokken (a, d) iş parçacığı %2–3 ve bu yol çalışmıyor (sessizlik kapısı, T-279).
2. **Video karesi alma yolunda üç ayırma ve dört kopya.** `mb-video` (c) örneklerinin %29'u `memcpy`/`System.arraycopy`. Kopyalar:
   - `RecordDecoder.feed` (soket → tampon);
   - `cipher.doFinal` (→ `scratch`);
   - `RecordOpener` `scratch.copyOf(n)` (**ayırma**);
   - `RecordDecoder.next` `plain.copyOfRange(1, n)` (**ayırma**);
   - `Codec.decodePayload` → `Reader.bytes(size)` (**ayırma**).

   Kare başına 100–300 KB'lık üç dizi büyük nesne alanına (LOS) düşüyor. Sonuçlar: oyunda GC tek çekirdeğin %14'ü, 7 000 minor fault/s. GC logunda dakikada ~60 LOS nesnesi (7–10 MB). AES-GCM'nin kendisi (`aes_hw_ctr32` + `gcm_ghash`) `mb-video`'nun ~%17'si; bu kaçınılmaz.
3. **Çözücü döngüleri sabit sürede yokluyor.** `VideoRenderer` giriş döngüsü 4 ms (`INPUT_WAIT_NS`), çıkış döngüsü 5 ms (`OUTPUT_WAIT_US`) bekliyor; `IdleWait` ancak 300 ms karesiz kalınca 20 ms'e çıkıyor. 10 fps akışta bu ~250 + ~250 uyanma/s ve MediaCodec iç döngüsünde ~450/s eder. Toplam ~950 uyanma/s ile çözücü iş parçacıkları %12 tek çekirdek; kare başına iş bunun küçük bir kısmı.
4. **AAudio sessizlik yazıyor.** Ses yokken `mb-audio` 200 uyanma/s ve %2,2 CPU harcıyor: MMAP tamponuna 5 ms'de bir sessizlik yazılıyor.
5. Küçükler:
   - ana iş parçacığında `render`/`applyStatusText` ve vsync, ana iş parçacığının %8–14'ü (≈%0,5–1);
   - `String.format`/log/istatistik, uygulama örneklerinin %0,3–2,3'ü (≈%0,1–0,6);
   - `AdaptivePacer.percentile` kare başına sıralama, ≈%0,4;
   - `QuickAck` okuma başına `setsockopt`, oyunda ≈%0,8;
   - "Explicit concurrent copying GC" dakikada bir, Binder iş parçacığından. Bizim kodumuzda `System.gc()` yok; çerçeve tetikliyor.

## Adaylar

Eşik (T-282 Kabul 5): ≥%2 tek çekirdek ya da ≥100 uyanma/s.

| Aday | Ölçülen maliyet | Tahmini kazanç | Risk / bedel | Karar |
|---|---|---|---|---|
| Örnekleyicide `roundToInt` yerine satır içi yuvarlama, yorumlayıcı yolunu kapat | `mb-audio` %34–39 (ses varken) | **%20–30** ses çalarken | Düşük. Saf fonksiyon, birim testleri var, çıktı bit bit aynı kalmalı. | **T-284** |
| Video alma yolunda kare başına ayırmayı kaldır (yeniden kullanılan tampon, dilim) | `mb-video` %13 + GC %14 (oyun); video %7 + %5 | **oyunda %10–15**, videoda %5–8; fault/s ~7 000 → <1 500 | Orta. Tampon ömrü kuyruktaki kareyle çakışmamalı. Güvenlik kodu, codex incelemesi gerekir. Protokol değişmez. | **T-285** |
| Çözücü döngülerinde sabit yoklama yerine olaya bağlı uyanma | 10 fps'te ~950 uyanma/s, %12 | **≥500 uyanma/s**, %3–8 | **Yüksek.** Gecikme yolu (T-077 giriş yuvası, T-141). Cihazda `latency_us`/`decode_ms` A/B şart. | **T-286** |
| Uzun sessizlikte AAudio akışını duraklat | %2,2 + 200 uyanma/s (ses yokken; günün çoğu) | %2 + 200 uyanma/s | Orta. İlk sesin gecikmesi ve tıkırtı. Yalnız uzun sessizlikte (≥10 sn), yeniden başlatma süresi ölçülür. | **T-287** |
| Ana iş parçacığı durum metni / vsync | ≈%0,5–1 | <%1 | | değmez |
| Log / istatistik maliyeti | ≈%0,1–0,6 | <%1 | Teşhis değeri yüksek | değmez |
| `AdaptivePacer` sıralaması, `HoldMeter` kutulama | ≈%0,4 | <%0,5 | | değmez |
| `QuickAck` `setsockopt` | ≈%0,8 (oyun) | <%1 | Gecikme ayarı (T-074) | değmez |
| Mac tarafı | Tek kalem <%2 | | | değmez |
| Günlük APK'yı debuggable olmayan (profileable) derlemek | **ölçülmedi** | bilinmiyor (tüm Kotlin yolları) | `run-as` kaybolur (tercih yazma, teşhis). İmza aynı kalmalı. | T-284/T-285 sonrası yeniden ölç |

## Kullanıcıya not

- Claude Code (ya da başka bir terminal animasyonu) Mac ekranında görünür bir pencerede çalışırken tablet ~10 fps alıyor. Bu, istemciye ~%15 tek çekirdek ve çözücüye ~950 uyanma/s ekliyor. Pencereyi küçültmek ya da başka masaüstüne taşımak akışı durdurur.
- Ses çalarken istemci CPU'sunun en büyük tek kalemi ses örnekleyicisi. T-284 sonrasında video ve oyunda istemcinin ~%105'ten ~%75–85'e inmesi bekleniyor [Tahmin].

## Ham veri

Ham çıktılar scratch'te kaldı, commit edilmedi: simpleperf `perf.data`, `top`, `sample`, host penceresi. Betikler: `dev_perf.sh` (tablette, `/data/local/tmp/mbperf_dev.sh`), `mac_perf.sh`, `an.py`, `sample_threads.py`. Kart sonrası ölçüm aynı yöntemle tekrarlanmalı. Betikler kayıpsa bu bölümdeki tarif yeterli.
