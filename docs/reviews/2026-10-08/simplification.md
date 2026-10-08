# Sadeleştirme ve optimizasyon — ortak ayıklama (T-297 + T-298), 2026-10-08

Kaynaklar:
- 6 sadeleştirme ajanı (Opus 5.5, salt okuma): `agents/simp-*.md`;
- 3 optimizasyon ajanı: `agents/opt-*.md`;
- gpt-6-astra (high): `astra-simplification.md`;
- ölçüm tabanı: T-296, `docs/research/2026-10-08-baseline.md`.

Ajan özetleri dosya:satır kanıtlarını taşır; uygulama kartları onlara başvurur. Orkestratörün doğruladıkları: B1 (kodda `register(` çağrısı yok), CB1 (`build.gradle.kts`'te `buildTypes` yok, günlük APK debug) ve astra'nın S1/S2 maddeleri (ajan bulgularıyla aynı).

## Özet

- **Karmaşıklığın gittiği yer:** temel aktarım değil. Yaşam döngüsü koordinasyonu, kurtarma ve isteğe bağlı medya yolları. Astra ve ajanlar aynı yargıda.
- **En büyük kolay kazanç: kararı verilmiş deneylerin kodu hâlâ duruyor.**
  - `tos_*`/`wifi_ll` ve Wi-Fi kilidi, `hz_pin`, renk geçersiz kılma anahtarları, `dec_lowlat`/`dec_oprate` varyantları;
  - host'ta `BITRATE_STEP` ve yalnız onun ulaştığı canlı bit hızı zinciri, `QUALITY`, `ENCODER=llrc`, `REFRESH`.
  - Toplam ~1.000–1.300 ürün satırı ve benzer miktarda test.
- **Ürün kodunda yalnız testte kullanılan kod:**
  - Kotlin `FrameDecoder` (127 satır);
  - Swift CPU referans modelleri (~250 satır, test hedefine taşınır);
  - kayıt katmanı artıkları;
  - `SlotReleaser` sınırlayıcı artıkları;
  - çok sayıda ölü üye.
- **`docs/KNOBS.md` kodla uyumsuz:** 11+ anahtar eksik, kaldırılmış satırlar eski referans taşıyor. PROTOCOL.md'de iki fixture listesi ayrı ayrı eskimiş; `check.sh` alt dize araması bunu yakalamıyor.
- **Güvenlik açığı (sadeleştirme değil), B1:** `HostSleepParticipants`'a üretimde hiç kayıt yapılmıyor. T-132'nin "uyku anında girdi bırakma oturum kuyruğundan bağımsız" güvencesi uygulanmamış. Girdi yine oturum kuyruğu üzerinden bırakılıyor; ama kuyruk takılırsa yedek yok. **İlk iş.**

## Uygulama partileri (öneri sırası)

Her parti bir kart, `check.sh`, Codex incelemesi ve gerekiyorsa kısa bir cihaz kontrolü. Aynı dosyaya dokunan bulgular aynı partide.

| # | Parti | İçerik (ajan kimlikleri) | Boyut | Risk | Karar gerekir mi |
|---|---|---|---|---|---|
| 1 | **Host uyku katılımcıları (hata)** | B1: InputController `input`, SystemAudioTap `audio` kaydı; `host_sleep_ack input= audio=` | ~30 | düşük; girdi kuralı | hayır |
| 2 | **İstemci deney artıkları** | D1 (tos/wifi_ll/kilit/`WAKE_LOCK`), D2 (`hz_pin`, `HzSwitchCounter` kalır), C5 (`color_*`), f: `dec_lowlat`/`dec_oprate` varyantları (`max` yeniden denemesi ve log alanları kalır), `VideoTestActivity` | ~−550 ürün, ~−700 test | düşük | hayır (kayıtlarda kararlı) |
| 3 | **İstemci ölü/test-yalnız kod** | C1, C3, C4, C8, C9, C11, D3, D8, E1, E2, E3, E8 | ~−350 ürün, ~−300 test | yok–düşük | hayır |
| 4 | **Host ölü kod ve kapanmış anahtarlar** | A3, A4, A5, A6, A9 (taşıma), B2, B3, B6 (ölü kısımlar), B10, B11, B12, E5, E7; f: `QUALITY`, `ENCODER=llrc`, `REFRESH`, `WIFI_BITRATE_KBPS` | ~−500 ürün | düşük | hayır |
| 5 | **Belgeler (orkestratör)** | `KNOBS.md` kodla eşitlenir; PROTOCOL fixture tek liste + `check.sh` tam ad (E4); LOGGING eskileri; `REFINE` → `knobAllowList` | belge | yok | hayır |
| 6 | **Host canlı bit hızı zinciri** | A1 / f #5: `BITRATE_STEP` + `setTargetBitrate` zinciri (~230 ürün, ~200 test) | orta | Codex high | **evet** (0023 eki; ileride uyarlama gerekirse git geçmişinden döner) |
| 7 | **Host Metal birleşik geçiş (perf)** | HA1 (Metal'e ayrı iz aşaması + csv `bytes`/`key`, EN4 ile aynı), HA2 (sharp_nearest tek dispatch, LUT `constant`), A8 (iki geçişin ortak kurulumu) | orta | düşük (bit-exact test) | hayır |
| 8 | **İstemci uyanma azaltma (perf, A/B anahtarı)** | CB2 (codec boşken çıkış iş parçacığı park eder), C6 (pacer yüzdelik ayırması), C10/CB9 (Tam renk aux çözücü ve GL bekleme) | küçük | düşük–orta; gecikme A/B | hayır |
| 9 | **Günlük derleme: debug değil (perf)** | CB1: `isDebuggable=false` + `profileable`, aynı imza, CMake Release; debug APK tanı için kalır | küçük | düşük | **evet** (`run-as` gider) |
| 10 | **Ölçüm logları (yalnız log)** | EN1 (istemci girdi gönderim yaşı), EN2/HA3 (`inject_to_frame`), EN5 (ısı/pil telemetrisi), CB8 (gereksiz ana iş parçacığı zamanlayıcıları) | küçük | yok | hayır |
| 11 | **Host çıkış kopyaları (perf)** | A2+A7+S4 (Annex-B yerinde, parametre setleri önbelleği, `type‖payload` doğrudan mühürleyiciye) | orta | orta (şifreleme yolu) | hayır; Codex high |
| 12 | **İstemci alım kopyası (perf)** | S5 (kimliği doğrulanmış düz metinden doğrudan ayrıştırma) | orta | orta | hayır; Codex high |
| 13 | **Yapısal (sonra)** | S3 (tek gönderici döngüsü), S7 (tek yapılandırma işlemi), S6 (video çıkış denetleyicisi), D5+D6 (MainActivity bölme), B5, B7, B8, S8 | büyük | orta–yüksek | sırayla, her biri cihaz kontrolüyle |

## Kullanıcı kararı gerekenler

1. **CB1:** günlük kullanım için debug olmayan APK. Kazanç: tahminen 60 fps'te tek çekirdeğin %5–10'u ve daha az titreşim. Bedel: `run-as` olmaz; tanı oturumlarında debug APK kurulur. **Önerim: evet.**
2. **Parti 6, canlı bit hızı:** `BITRATE_STEP` ve canlı bit hızı ayarlayıcısı kaldırılsın mı? Rakiplerde ağ uyarlaması var (Parsec), ama 0023 "sabit profil yeterli" dedi. Gerekirse git geçmişinden geri gelir. **Önerim: kaldır.**
3. **Sabit titreşim tamponu (`--ei jitter 0..2`, `FramePacer`):** 0026 §7 hâlâ "geliştirici için kalsın" diyor. Kaldırılırsa çözücü sıcak yolunda bir dal ve ~90 satır gider. **Önerim: kaldır;** uyarlamalı zamanlayıcı her modda varsayılan ve ölçülmüş.
4. **minSdk 29 → 31 (D7):** tek cihaz API 31. Girdi sıcak yolunda bir kontrol ve ~40 satır gider. **Önerim: evet.**
5. **`MATEBRIDGE_CHROMA=444` ve `sharp_bilinear` (0033):** `444` tablette çıktı vermedi, `bilinear`'ı kullanıcı seçmedi. **Önerim: kaldır.**
6. **`MATEBRIDGE_VD_TRANSFER` (0032):** HDR10 akışı bunun yerini aldı; ama özel API dosyasına dokunuyor. **Önerim: kaldır,** ayrı ve küçük bir kart.
7. **`probes/` (10 prob, ~19,9 bin satır):** hepsi sonuçlandı ve yerel `check.sh` hepsini derliyor. **Önerim: `check.sh` tam çalıştırmasından çıkar.** Arşive taşımak `docs/archive` kuralına takılır; ayrı bir klasör olur.
8. **Protokol anlamı (E9):** `str8` içinde geçersiz UTF-8. Swift kayıplı kabul ediyor, Kotlin reddediyor. **Önerim: iki taraf da reddetsin,** fixture eklensin (orkestratör).

## Ölçüm gerektiren optimizasyonlar (T-298, sıralı)

| Kimlik | Ne | Neden önemli | Yöntem |
|---|---|---|---|
| CB4 | 60 fps'te çözme 13–14 ms (Çizim 120'de 9 ms) | Huawei'nin girdi sırasında saat yükseltmesi şüphesi; gecikmede −4 ms'ye kadar | Oyun 60: trackpad parmağı vs klavye, `cpufreq`/`devfreq` 10 Hz; `KEY_FRAME_RATE` kolları |
| CB5 | SurfaceFlinger birleştirme türü | sf %11–15, HAL %13; video katmanı CLIENT ise her karede GPU geçişi | `dumpsys SurfaceFlinger`, imleç katmanı açık/kapalı |
| CB6/EN5 | Ekran enerjisi | Hiç veri yok. Parlaklık ve 120 Hz en büyük kaldıraçlar | T-296 pil kolları + telemetri |
| EN8 | DSCP hatta var mı | macOS `SO_NET_SERVICE_TYPE` ToS 0 yazıyor olabilir; T-124 sınıfları AP'de etkisiz olabilir | `tcpdump -v`; 0 ise açık `IP_TOS` anahtarı |
| EN9 | Kare boyutu tavanı (`RATE_WINDOW_MS` 17/33/50) | Wi-Fi'de tam ekran değişimleri 110–145 ms; **f-#5 kaldırmadan önce ölçülmeli** | A/B, `cap_dec` p95 |
| HA4 | IDR yerine LTR P-kare ile kurtarma | Kurtarma kareleri 3–10× küçük | önce `keyframe_request` nedenleri sayılır; HiSilicon LTR probu |
| EN3 | Parmak, trackpad ve fare için tamponsuz dağıtım | 120 Hz'de ortalama ~4 ms | anahtar arkasında A/B |
| CB7 | Wi-Fi'de video soketinde QUICKACK kapalı | ~%0,8 çekirdek ve 2× ACK, gecikme farkı yok | `--ez quickack false` A/B |
| EN10 | USB 2.0 (480 Mb/s) | büyük karelerde ~8–10 ms | C-C SuperSpeed kablo denemesi (kullanıcı) |
| EN7 | Ekrandan ekrana optik ölçüm (T-174) | 4 kör segmentin toplamı | kullanıcıyla, telefon 240 fps |

## Ölçüm tabanından çıkan yeni bulgular

Ayrıntı ve sayılar: `docs/research/2026-10-08-baseline.md`.
- **Hareket sahnesinde (60 fps, 60 Hz) `skip_pct` %35.** Panel hızında içerikte bu kadar atlama beklenmez → zamanlayıcı ve panel incelemesi (yeni kart).
- **Sentetik kalem (~980 örnek/s, gerçek kalemin 2–4 katı):**
  - host %60 CPU (her örnek için ~0,6 ms), WindowServer %32;
  - kontrol bağlantısında gidiş-dönüş 108 ms, kalem yaşı ~55 ms, `cap_dec` p50 60 ms;
  - `max_batch=1`: her örnek ayrı kayıt olarak gidiyor.

  Gerçek kalem hızında etkisi daha küçük, ama örnek başına host maliyeti ve kayıt başına gönderim incelenmeye değer (yeni ölçüm kartı; gerçek kalem verisiyle karşılaştırılır).

## Reddedilen ya da kalması gerekenler (özet)

Ayrıntı ajan dosyalarında. Kalacaklar:
- girdi güvenliği yolları ve bekçiler;
- `EncoderSubmitOrder` tek sahip;
- 0019 kuşak ve emeklilik kuralları;
- `AuxFrameQueue`'nun ayrı durması;
- AudioTrack yedeği;
- `catch_up` / `cursor_predict` / `audio` / `audio_idle_pause` / `REFINE=0` kapatma anahtarları;
- host CLI ölçüm araçları;
- iki taraftaki bağımsız fixture doğrulaması;
- Metal geçişlerindeki eşzamanlı bekleme (sıralama).

HA2'nin "tamamlanma işleyicisi" alt maddesi bu nedenle **ertelendi**.

Çelişki notları:
- **`hz_pin`:** D2 kaldırmayı öneriyor; CB6 ise pilde 60 Hz tavanı için `hz_pin` LP_MINMAX'i öneriyor. `hz_pin`'in cihazdaki sonucu olumsuzdu (HarmonyOS uymadı). Kaldırma geçerli; pilde 60 Hz fikri ayrı bir deney olarak yeniden açılabilir.
- **`RATE_WINDOW_MS`:** f kaldırmayı öneriyor, EN9 ölçmeyi. Önce ölçülür.
