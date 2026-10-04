# Deney ayarları (knob) envanteri

Karar: [0026](decisions/0026-experiment-knobs.md) (kabul, 2026-10-03). Kart: T-182.
Kaynak tablo: `docs/reviews/2026-10-03/verify-H-hygiene.md` (L02 envanteri, HEAD a30c769). Bu dosyadaki her satır `main` `ef264dd` üzerinde koda karşı yeniden doğrulandı; dosya:satır referansları o commit'e aittir.

**Kural (0026 §2):** yeni bir ayar eklenince ya da kaldırılınca bu dosya aynı commit'te güncellenir. Yeni ayarın varsayılanı kapalıdır ve onu benimseyecek ya da kaldıracak kartı adlandırır.

## Sınıflar

- **kalır (keep):** günlük özellik ya da gerekli bir tanı aracı. Olduğu gibi kalır.
- **yalnızca geliştirici (debug-only):** kalır ama işaretlenir. (T-185 uygulandı: `DevKnobs.kt`; yok sayılan anahtarlar `diag ev=dev_knobs ignored=` satırında.)
  - İstemcide yalnızca aynı açılışta `--ez dev true` verilirse dikkate alınır (T-185). Günlük APK debug varyantı (`scripts/install-apk.sh`, `buildTypes` yok), bu yüzden build türüne göre ayırmak yetmez.
  - Host'ta bir kapı yok. Varsayılan dışı değerler `ev=profile` satırında listelenir (T-204).
- **kaldırılır (retire):** kod silinir. Deney olumsuz ya da etkisiz sonuçlandı veya başka bir çözüm onun yerini aldı. Geri getirmek için git geçmişi kullanılır.

Kısaltmalar:
- `MA` = `client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt`
- `VR` = `…/client/video/VideoRenderer.kt`; `…/client/` = `client-android/app/src/main/kotlin/dev/matebridge/client/`
- `HE` = `host-mac/Sources/MateBridgeHost/Video/HEVCEncoder.swift`
- `EK` = `host-mac/Sources/MateBridgeCore/Video/EncoderKnobs.swift`
- `VS` = `host-mac/Sources/MateBridgeCore/Video/VideoSettings.swift`
- `TK` = `host-mac/Sources/MateBridgeCore/Session/TransportKnobs.swift`
- `SS` = `host-mac/Sources/MateBridgeHost/Session/SessionServer.swift`
- `N:` = `docs/NOTES.md` satırı

## Sayım (ef264dd)

| Taraf | Sayı | Komut |
|---|---|---|
| İstemci açılış parametreleri | 33 farklı anahtar (+4 `net_bench` alt anahtarı) | `grep -rnoE 'get(Int\|String\|Boolean)Extra\("[a-z_0-9]+"' client-android/app/src/main` → `MainActivity` 26 anahtar (`connected` hariç, aşağıya bkz.); `WifiKnobs.parse` 4 (`ping_ms`, `tos_ctl`, `tos_video`, `wifi_ll`); `EXTRA` sabitleri 3 (`net_bench`, `audio_out`, `audio_buf_bursts`) |
| Host ortam değişkenleri | 25 farklı `MATEBRIDGE_*` | `grep -rhoE '"MATEBRIDGE_[A-Z0-9_]+"' host-mac/Sources \| sort -u` |
| Host CLI kipleri | 4 | `host-mac/Sources/MateBridgeApp/main.swift:6-9` |

Sınıf dağılımı (anahtar başına):
- İstemci: kaldırılır 16, yalnızca geliştirici 14 (+4 alt anahtar), kalır 3.
- Host env: kaldırılır 11, yalnızca geliştirici 11, kalır 3.
- CLI: kalır 4.

Sayıma girmeyen okumalar (açılış parametresi değil ya da başka giriş noktası):
- `MA:1750` `getBooleanExtra("connected")`: USB durum yayınının (`ACTION_USB_STATE`) alanı.
- `MA:1752` `BatteryManager.EXTRA_PLUGGED`: pil yayını.
- `client-android/app/src/debug/…/debug/VideoTestActivity.kt:43-45` `fps`, `full_range`, `primaries`: yalnızca debug kaynak setindeki test etkinliği (kalır, araç). Bkz. *Açık noktalar* 2.

## İstemci açılış parametreleri (33)

| # | Ayar | Varsayılan | Nerede (ef264dd) | Kart / kanıt | Sınıf | Sonuç | Uygulayan |
|---|---|---|---|---|---|---|---|
| 1 | `--ei jitter N` (sabit tampon 0–2, `FramePacer`; `-1` = uyarlamalı `AdaptivePacer`, T-210; `0` oyun modunda eski tampon 0 A/B'si, T-211; diğer değerler 0–2'ye sınırlanır) | yok = uyarlamalı (`BUFFER_ADAPTIVE`). Oyun modları da uyarlamalı (0014 §2, 2026-10-04; `GameJitter`) | MA:376-386; VR:368, :534; `…/stream/GameMode.kt:107-111`; `VsyncClock` `…/video/FramePacer.kt:18` | T-016/T-052, T-210, T-211 | yalnızca geliştirici | Uyarlamalı pacer varsayılan (T-052). Tampon 1–2'nin T-052'den beri kayıtlı bir cihaz kazancı yok. 1–2 dalı **açık nokta**, bkz. aşağı | T-185 (kapı) |
| 2 | `--ei hz N` | -1 = akışı izler (`FrameRatePolicy.HZ_FOLLOW_STREAM`) | MA:413 | T-046 | yalnızca geliştirici | 60/120 A/B için yararlı | T-185 |
| 3 | `--ei oprate 0/-1/-2/N` | 0 = akış fps'i | MA:375; VR:284; `…/video/OperatingRate.kt` | T-052; N:315 (HiSilicon `KEY_OPERATING_RATE`'i kabul etmiyor) | **kaldırıldı (T-183, 2026-10-03)** | Ayar silinir. Varsayılan davranış (rate = akış fps) T-183 etkisiz olduğunu gösterene kadar kalır | T-183 |
| 4 | `--es render gl`, `--ei frate`, `--ez glpts` (GL sunum yolu) | `surface`; `frate` -1; `glpts` false | MA:369-371, :376-385 (`glMode` dalları), :434-439; MA'da GL'ye özgü ~35 satır; `…/video/GlPresenter.kt` (366 satır); `res/layout/activity_main.xml:15` (`video_gl`) | T-018 bitti; T-019 park; N:132-136 | **kaldırıldı (T-184, 2026-10-03)** | HarmonyOS GL yüzeyini de 60 Hz'de tutuyor. T-019 tamponu gözle daha kötüydü ve soğuk başlangıçta kare gelmeme hatası vardı. İki ayrı yüzey yaşam döngüsü (H02/M03 riski) | T-184 |
| 5 | `--ez stats_1s true` | false (10 s pencere) | MA:373-374 | T-141; N:1079-1083 | kalır (tanı) | Ölçüm koşuları için gerekli; varsayılan güç tasarrufu sağlar | — |
| 6 | `--ei inflight N` | 0 = sınırsız | MA:387, :1162, :1290; VR:89, :447 | T-057; N:342 | **kaldırıldı (T-183, 2026-10-03)** | inflight 3/4 ölçümde daha kötü (%6,3/%8,6 tekrar). FrameQueue ile anahtar kare döngüsü riski | T-183 |
| 7 | `--ei lead_us N` | yok = 6 ms (`VsyncClock.DEFAULT_LEAD_NS`, FramePacer.kt:27) | MA:388-391 | T-057/T-061; N:352-354 | yalnızca geliştirici | Tarama sabit 6 ms'de bitti; OS güncellemesinden sonra yeniden ayar için kalır | T-185 |
| 8 | `--ei deadline_us N` | yok = 6 ms (`DEFAULT_DEADLINE_NS`); -1 = ekranın bildirdiği | MA:392-398 | T-071; N:388-393 | yalnızca geliştirici | 6 ms benimsendi; HarmonyOS 13,33 ms bildiriyor | T-185 |
| 9 | `--ez keep_jitter`, `--ez recenter` | false, false | MA:399-400; `…/video/FramePacer.kt:69-70` (`VsyncClock` alanları); `…/video/AdaptivePacer.kt:81`, :248-253; VR:165 | T-067 (sonuçsuz, park) | **kaldırıldı (T-183, 2026-10-03)** | Tek ölçüm karışıktı (kullanıcı Mac'te 30 fps içerik oynatıyordu). Varsayılan pacer içinde ölü dallar. T-067 "yapılmayacak" kapandı | T-183 |
| 10 | `--es pacer cpd`, `--ei cpd_q_permille`, `--ei cpd_hold_us` | `lock`; 950; 2000 | MA:401-407; `…/video/ConstantPlayoutPacer.kt` (139 satır); VR:79-83, :377-380, :560 | T-080; N:446-453 | **kaldırıldı (T-183, 2026-10-03)** | Kullanıcı gecikmeyi hissetti ("ikincisinde gecikme hissediliyor"). `tools/pacing/sim.py` ve `trace7_120hz_excerpt.csv` kalır | T-183 |
| 11 | `--ez pace_trace true` | false | MA:187, :408, :1164-1165; `…/video/PaceTrace.kt` (284 satır); `…/security/Records.kt:53` (`stampOpens`) | T-069/T-073/T-077 | kalır (tanı) | `tools/pacing` tekrar oynatma malzemesinin kaynağı. Kapalıyken tek bir volatile okuma | — |
| 12 | `--ez crypto_bench true` | false | MA:409-412; `…/security/Records.kt:120` (`runBench`) | T-076; N:421 | **kaldırıldı (T-183, 2026-10-03)** | Tek seferlik, sonuçlandı: AndroidOpenSSL zaten varsayılan (776 MB/s) | T-183 |
| 13 | `--ez perf_hint`, `--ei perf_hint_target_us` | false; 0 = panel periyodu | MA:345-354; `…/video/PerfHint.kt` (178), `…/video/AndroidPerfHint.kt` (30); VR:99-100, :331-337, :402-407, :428, :473-476 | T-079; N:439 | **kaldırıldı (T-183, 2026-10-03)** | HarmonyOS 4.3'te `createHintSession` oturum vermiyor (`session=0`) | T-183 |
| 14 | `--ei ping_ms N` | 500 (20–1000) | `…/session/WifiKnobs.kt:24-30`; MA:310-315 | T-089 | yalnızca geliştirici | 3 s PONG zaman aşımı sözleşmesini koruyor; zararsız | T-185 |
| 15 | `--ei tos_ctl`, `--ei tos_video`, `--ez wifi_ll` (+ `WifiLockHolder`, `WAKE_LOCK`) | işaretsiz; işaretsiz; false | `…/session/WifiKnobs.kt:31-32`, :108 (`WifiLockHolder`); MA:310-338; `AndroidManifest.xml:6-7` | T-089; N:581-597 | **T-127'ye kadar yalnızca geliştirici** (audit K4) | 2026-10-01 "etkisiz" sonucu `nw` yığınında, bağlantı ~27–28 Mbps tavanında doygunken ölçüldü; QoS işareti etki gösteremezdi. T-124'te host servis sınıfı `bsd` altında yardımcı oldu (N:958-959). T-127 sonrası orkestratör burada kalır/kaldırılır yazar | T-185 (kapı); T-127 karar verir |
| 16 | `--ei rvote`, `--ei rvote_min_fps`, `--ei rvote_prio` (gizli API yansıması) | 0 (kapalı); 70; 0 | MA:230-235, :294-308, :433, :632, :1198, :1388, :1792; `…/video/RefreshVote.kt:149-150` (186 satır) | T-140; N:1072-1078 | **kaldırıldı (T-183, 2026-10-03)** | Olumsuz: panel %100 60 Hz kaldı. `Class.forName("android.view.DynamicRefreshRateHelper")` OS güncellemesinde kırılabilir | T-183 |
| 17 | `--ez audio false` | true | MA:417-418 | T-095 | yalnızca geliştirici | Panelde "Ses" var; ayar ayrıca HELLO ses bitini düşürür (sesi yalıtmak için) | T-185 |
| 18 | `--es transport auto/usb/wifi` | kayıtlı ayar (değiştirilmez) | MA:419-422 | T-096 | yalnızca geliştirici | Tek açılışlık geçersiz kılma; USB/Wi-Fi A/B için yararlı | T-185 |
| 19 | `--es audio_out aaudio/track/auto` | kayıtlı ayar | MA:487; `…/audio/AudioPlayout.kt:114`; `…/audio/SinkPolicy.kt:24` | T-100/T-101 | yalnızca geliştirici | Panel "Ses çıkışı" seçimini kaydetmeden yineler | T-185 |
| 20 | `--ei audio_buf_bursts N` | yok = AudioTrack 1, AAudio max(4, hatırlanan) burst; 1–6 | `…/audio/AudioPlayout.kt:94`; `…/audio/AudioBufferConfig.kt:14` | T-110/T-114 | yalnızca geliştirici | Geçersiz kılmadan sonraki büyüme kalıcı öğrenilmiş duruma sızıyor (T-110); sıfırlama T-191'de | T-185, T-191 |
| 21 | `--ez quickack false` | true | MA:494-496; `…/session/QuickAck.kt:32` | T-074; N:415-420 | yalnızca geliştirici | Varsayılan açık A/B ile kanıtlandı (79'a karşı 1 geç varış); kapatma A/B için kalır | T-185 |
| 22 | `--ez stall_diag true` | false | MA:497-498; `…/diag/StallDetector.kt` | T-120/T-142; N:1088 | kalır (tanı) | Zaten isteğe bağlı | — |
| 23 | `--es net_bench host:port` (+ `net_bench_s`, `net_bench_dir`, `net_bench_streams`, `net_bench_rcvbuf_kb`) | yok; alt anahtarlar 8 s (1–600), `down`, 1 (1–4), işletim sistemi varsayılanı (≤ 65 536 KB) | MA:359-366; `…/bench/NetBench.kt:39-59`; `…/bench/NetBenchActivity.kt:33`; `…/bench/*` (322 satır); `AndroidManifest.xml:34-39` | T-090 | yalnızca geliştirici; `src/debug` kaynak setine taşınır | `NWConnection` kök nedenini kanıtladı; nadiren gerekli | T-185 |
| 23b | `--es decoder_fault create/configure/dequeue/silent`, `--ei decoder_fault_after_s N` | yok; 10 | `client-android/app/src/main/kotlin/dev/matebridge/client/video/DecoderFault.kt` | T-159 (bu envanterden sonra eklendi) | yalnızca geliştirici | Hata enjeksiyonu; FLAG_DEBUGGABLE + `dev` kapısı | T-185 |
| 23c | `--ei game_display 0` | yok = "Oyun çözünürlüğü" ayarı (varsayılan 1848×1214) Oyun 120/60'ta STREAM_PREFS `display_*` ile gider; `0` = grup yok (0×0, doğal HiDPI ekran; T-215 öncesi baytlar). Başka değerler yok sayılır | `client-android/app/src/main/kotlin/dev/matebridge/client/session/DevKnobs.kt` (`gameDisplay`); `…/stream/GameMode.kt` (`GameModeSettings.display/prefs`) | T-215, karar 0029 (bu envanterden sonra eklendi) | yalnızca geliştirici | Oyun ekranı ile doğal ekranın A/B'si (T-216). `ev=profile` `display=` alanında görünür | T-215 |
| 23d | `--es dec_lowlat off/hisi/vdec/all`, `--es dec_oprate fps/max` | yok = `off`, `max` (T-222; `fps` = T-217 öncesi format, bayt bayt) | `…/session/DevKnobs.kt` (`decoderLatency`); `…/video/OperatingRate.kt` (`DecoderLatencyKnobs`); VR `createCodec` | T-217 (bu envanterden sonra eklendi); araştırma 2026-10-04 §1, §4 | yalnızca geliştirici | HiSilicon decoder gecikme anahtarları A/B: `hisi` = `vendor.hisi-ext-low-latency-video-dec.video-scene-for-low-latency-req=1` + `…-rdy=-1`; `vdec` = `vdec-lowlatency=1` + `low-latency=1`; `all` = dördü; `max` = `KEY_OPERATING_RATE=32767`. configure/start hatasında anahtarsız (akış fps'li) tek yeniden deneme (`dec_lowlat_rejected`), varsayılan `max` için de. T-217 cihaz A/B'si (NOTES 2026-10-04) sonucu T-222 `max`'ı varsayılan yaptı (60 fps'te çözme ~−4 ms, `cb_skip_pct` p90 %24→%2); `dec_lowlat` varsayılanı `off` kaldı (`vdec-lowlatency` reddediliyor, `hisi` ~0,2 ms). `MainActivity.installConfig` → `VideoRenderer(decoderTuning=)` | T-217, T-222 |

## Host ortam değişkenleri (25; T-186 sonrası 23, T-165/T-177 ile +3 okunuyor)

Host'ta geliştirici kapısı yok. "Yalnızca geliştirici" burada: kalır, varsayılan dışı değeri `ev=profile` satırında görünür (T-204).

| # | Ayar | Varsayılan | Nerede (ef264dd) | Kart / kanıt | Sınıf | Sonuç | Uygulayan |
|---|---|---|---|---|---|---|---|
| 24 | `MATEBRIDGE_FPS`, `MATEBRIDGE_BITRATE_KBPS` | tabletten türetilen fps (geçersiz değer 60); mod varsayılanı / STREAM_PREFS (5 000–150 000) | VS:59-69, :77-82; Core `EncodeBench.swift:101` | T-045/T-086 | yalnızca geliştirici | Env bit hızı STREAM_PREFS'i ezer (VS:20); `ev=profile`'da görünmezse sonuçlar yanlış etiketlenir | T-204 (profil) |
| 25 | `MATEBRIDGE_CODEC`; `MATEBRIDGE_H264_PROFILE` | `hevc`; `high` | VS:83; EK:3-20, :166, :192-194; `host-mac/Sources/MateBridgeCore/Video/EncodeBench.swift:95-100`; `SharpnessBenchOptions.swift` | T-082/T-086; N:532 | CODEC: yalnızca geliştirici. H264_PROFILE: **kaldırıldı (T-204)** | M6'da H.264 2800×1840@120'ye yetişmiyor (~24 ms); codec uyumluluk hata ayıklaması için kalır | T-204 |
| 26 | `MATEBRIDGE_REFRESH=60/120` | fps 120 ise 120, değilse 60 | VS:47-50, :84-85; `StreamCoordinator.swift:190`, :376 | T-017 | yalnızca geliştirici | Varsayılan fps'ten türetilir | T-204 (profil) |
| 27 | `MATEBRIDGE_FRAME_DELAY=0/1` | yok (kodlayıcı varsayılanı) | VS:19, :53-56, :86; HE:164-166; yorum `StreamCoordinator.swift:182-184` | T-017 (hiç ölçülmedi, benimsenmedi) | **kaldırıldı (T-204, 2026-10-03)** | Ölü deney | T-204 |
| 28 | `MATEBRIDGE_ENCODER=llrc/fast` | `fast` (her fps'te) | HE:130-136; `host-mac/Sources/MateBridgeCore/Video/EncoderProfile.swift:10-11` | T-053/T-087 | yalnızca geliştirici | `llrc` yalnızca ≤ 60 fps'te anlamlı (~10 ms/kare) | T-204 (profil) |
| 29 | `MATEBRIDGE_IDLE_REFRESH_MS`, `_COUNT`, `_KEY`, `_BUFFER`, `_QP` (zamanlayıcı, QP artırma, kopya havuzu) | 0 = kapalı; 3; 0; `same`; yok | EK:34-95; HE:29-30, :71-86, :124-128, :207-212, :220, :343-349, :434-472, :563, :667-671 | T-086/T-087; N:562-579 | **kaldırıldı (T-204, 2026-10-03)** | Gerçek hatta 222 baytlık atlama kareleri; `fast` profil akış ortası QP'yi yok sayıyor; bench kazancı ısınma yanılgısıydı. Açıkken kodlayıcıya üçüncü bir çağıran (zamanlayıcı) ekler (M02). `resubmitLast` (durağan anahtar kare yolu) kalır | T-204 |
| 30 | `MATEBRIDGE_PRIO_SPEED=0`; `MATEBRIDGE_QUALITY` | 1 (hız öncelikli); yok (AverageBitRate) | EK:164-165; HE:169-189 | T-086; N:542 | PRIO_SPEED: **kaldırıldı (T-204)**. QUALITY: yalnızca geliştirici | PRIO_SPEED=0 ~25 ms kodlama, kullanılamaz. QUALITY olası bir metin netliği profili | T-204 |
| 31 | `MATEBRIDGE_KEYFRAME_INTERVAL_S` | 300 (en çok 3600) | `host-mac/Sources/MateBridgeCore/Video/KeyframeIntervalPolicy.swift:10-20`; HE:271 | T-075; N:420 | yalnızca geliştirici | 300 s benimsendi | T-204 (profil) |
| 32 | `MATEBRIDGE_INPUT_RETAG=0` | 1 (açık) | `host-mac/Sources/MateBridgeCore/Video/InputColorTags.swift:36-38`; EK:153-163; HE:318; Core `EncodeBench.swift:102` | T-113; N:758-805 | **kaldırıldı (T-204; retag her zaman açık)** | Düzeltme kanıtlandı (−2,7 ms, doğru renk); `=0` bilinen bir renk/gecikme hatasını geri getirir | T-204 |
| 33 | `MATEBRIDGE_WIFI_BITRATE_KBPS` | yok | `host-mac/Sources/MateBridgeCore/Video/TransportBitrate.swift:20-28` | T-088 | yalnızca geliştirici | Bugün tek Wi-Fi bit hızı sınırı; H03 girdisi. T-178 Wi-Fi varsayılanı ekler | T-204 (profil) |
| 34 | `MATEBRIDGE_SERVICE_CLASS` | `signaling` | TK:21-43 | T-088/T-124; N:958-959 | yalnızca geliştirici | `signaling` varsayılan olarak benimsendi | T-204 (profil) |
| 35 | `MATEBRIDGE_VIDEO_SOCKET=nw`, `MATEBRIDGE_CONTROL_SOCKET=nw` | `bsd`, `bsd` | TK:79-95, :138-153; SS:3, :34-38, :112-115, :336-375, :561-600, :955-987, :1125-1205; `host-mac/Sources/MateBridgeHost/Session/TcpSocketProbe.swift` (NWConnection varyantı) | T-091/T-092/T-111; N:620-643 | **kaldırıldı (T-186, 2026-10-03)** | `NWConnection`'ın kullanıcı alanı TCP'si Wi-Fi'de ~27 Mbps tavan ve yeniden iletimler. Bonjour `BonjourAdvertiser`'da kalmalı (SS:228, :1084) | T-186 |
| 36 | `MATEBRIDGE_NOTSENT_LOWAT_KB` | 128 (16–4096) | TK:98-112 | T-091; N:643 | yalnızca geliştirici | H03 ayarı; 64/128/256 farkı gürültü düzeyinde | T-204 (profil) |
| 37 | `MATEBRIDGE_SENDQ_LOG`, `MATEBRIDGE_LAT_TRACE` | 0, 0 | TK:69-76; SS:309; `host-mac/Sources/MateBridgeHost/Video/LatencyCsv.swift:13`; `VideoPipeline.swift:38` | T-070/T-088 | kalır (tanı) | H03/H05/M07 izleri için gerekli | — |
| 38 | `MATEBRIDGE_TCP_LOG` | `auto` (yalnızca Wi-Fi) | `host-mac/Sources/MateBridgeCore/Session/TcpInfoLog.swift:129-145`; SS:311 | T-126 | kalır (tanı) | — | — |
| 39 | `MATEBRIDGE_AUDIO=off` | açık | `host-mac/Sources/MateBridgeCore/Audio/AudioStreamer.swift:32-35`; `HostAudio.swift:12` | T-094 | yalnızca geliştirici | Yalıtım anahtarı | T-204 (profil) |
| 40 | `MATEBRIDGE_DISPLAY_KEEP_S` | 10 (10–86 400; geçersiz değer 10) | `host-mac/Sources/MateBridgeCore/Video/DisplayLease.swift` | T-165 (2026-10-03, bu envanterden sonra eklendi) | yalnızca geliştirici | Bekletilen sanal ekranın süresi (duvar saati). Kullanıcıya açılan seçim T-167 (karar 0020) | T-167 (menü) |
| 41 | `MATEBRIDGE_BITRATE_STEP=<kbps,…>@<n>s` | kapalı | `host-mac/Sources/MateBridgeCore/Video/EncoderKnobs.swift` (`BitrateStepKnob`); `EncoderSubmitOrder.swift` | T-177 (2026-10-03) | yalnızca geliştirici | Canlı bit hızı setter'ını cihazda sınamak için zamanlayıcıyla adım | T-196 ya da T-127 sonrası kaldırılır |
| 42 | `MATEBRIDGE_RATE_WINDOW_MS` | kapalı (10–999) | `EncoderKnobs.swift`; `HEVCEncoder.swift` | T-177 (2026-10-03) | yalnızca geliştirici | Kısa `DataRateLimits` penceresi (tanı). 100 ms tek bir 100–450 KB kareyi sınırlamaz; cihazda 33 ve 100 denenir | T-127 sonrası karar |

## Host CLI kipleri (4) ve derleme zamanı

| # | Ayar | Nerede | Kart | Sınıf | Sonuç |
|---|---|---|---|---|---|
| 40 | `--dump-video`, `--encode-bench`, `--sharpness-bench`, `--inject-test` | `host-mac/Sources/MateBridgeApp/main.swift:6-9` | T-011/T-047/T-086/T-023 | kalır (araç) | Bench'ler host'taki tek tekrarlanabilir ölçüm. Ayrı bir çalıştırılabilir hedefe taşımak isteğe bağlı, kartı yok |
| — | `MATEBRIDGE_SIGN_IDENTITY` | `scripts/bundle-host.sh:14`, :38 | T-006 | kalır (derleme zamanı) | Çalışma zamanı ayarı değil |
| — | `--ei draw_scale` | (yok) | T-144 geri alındı | zaten kaldırıldı | Ölç ve geri al örneği |

## Açık noktalar

1. **Jitter tamponu 1–2 dalı (0026).** *(Orkestratör: yalnızca geliştirici olarak kalır, 2026-10-03.)* Soru: `--ei jitter 1|2` dalı (ve onunla `FramePacer` sınıfı) da kaldırılsın mı? 2026-10-03 onayı GL ve `nw` içindi; bu dal için ayrı bir cevap kayıtlı değil. Bu yüzden şimdilik **yalnızca geliştirici** kalır: T-183 `FramePacer`'ı silmez, T-185'in `--ei jitter 1` kabul kriteri geçerli. Kullanıcı kaldırmayı seçerse küçük bir izleme kartı `FramePacer`'ı siler ama `VsyncClock`'u (`FramePacer.kt:18`, günlük yol) korur; `jitter 0` Oyun modu üzerinden ulaşılabilir kalır.
2. **`VideoTestActivity` dışa açık.** *Çözüldü (T-185): dışa açık kalır (adb `am start` için) ama `android:permission="android.permission.DUMP"` ile korunur; onu yalnızca adb kabuğu başlatabilir.* `client-android/app/src/debug/AndroidManifest.xml` onu `exported="true"` tanımlıyor ve günlük APK debug varyantı. Bu yüzden tabletteki her uygulama onu (`fps`, `full_range`, `primaries` parametreleriyle) başlatabilir. Uygulama yalnızca uygulamanın kendi dosyasından (`test.h265`) okuyor. T-185'in `dev` kapısı yalnızca `MainActivity`'yi kapsar. Orkestratör karar verir (ör. T-185'e `exported="false"` eklemek).

## Planlanan ayarlar

Geldiklerinde buraya satır eklenir; hepsinin varsayılanı kapalı:
- T-196: `MATEBRIDGE_WIFI_ADAPT`.
- T-197: `ctl_lowat_kb` (`WifiKnobs.kt`'ye).
- T-198: `MATEBRIDGE_PEN_PLAYOUT_MS`.
