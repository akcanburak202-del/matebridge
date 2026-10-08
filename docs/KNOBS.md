# Deney ayarları (knob) envanteri

Karar: [0026](decisions/0026-experiment-knobs.md) (kabul, 2026-10-03). Kart: T-182.
Kaynak tablo: `docs/reviews/2026-10-03/verify-H-hygiene.md` (L02 envanteri, HEAD a30c769). İlk sürüm `ef264dd`'de doğrulandı.

**2026-10-08 eşitlemesi (T-297 parti 5):** her satır `main` `51e6b392` üzerinde koda karşı yeniden doğrulandı (T-295, T-300–T-304, T-307, T-309, T-311 sonrası). Canlı satırlarda dosya referansı `yol` (`sembol`) biçimindedir, satır numarası yoktur. Kaldırılan satırlar geçmiş için kalır, dosya referansları silindi. `N:` referansları `docs/NOTES.md` satırlarıdır (dosya yalnız sona eklenir, numaralar geçerli).

**Kural (0026 §2):** yeni bir ayar eklenince ya da kaldırılınca bu dosya aynı commit'te güncellenir. Yeni ayarın varsayılanı kapalıdır ve onu benimseyecek ya da kaldıracak kartı adlandırır.

## Sınıflar

- **kalır (keep):** günlük özellik ya da gerekli bir tanı aracı. Olduğu gibi kalır.
- **yalnızca geliştirici (debug-only):** kalır ama işaretlenir.
  - İstemcide yalnızca aynı açılışta `--ez dev true` verilirse dikkate alınır (T-185; `…/session/DevKnobs.kt` `SPECS`). Yok sayılan anahtarlar `diag ev=dev_knobs ignored=` satırında.
  - Kapı derleme türünden bağımsızdır. T-301'den beri tablete varsayılan olarak debug olmayan `daily` APK kurulur (`scripts/install-apk.sh`; `--debug` debug APK'yı kurar; karar 0037). Kapı iki APK'da da çalışır.
  - İki istisna yalnız debug APK'da çalışır: `decoder_fault` ayrıca `FLAG_DEBUGGABLE` ister; `net_bench` debug kaynak setindedir (daily'de `W diag ev=net_bench err=not_in_build`).
  - Host'ta bir kapı yok. Varsayılan dışı değerler `ev=profile knobs=` satırında listelenir (T-204; `StreamProfileLog.knobAllowList`).
- **kaldırılır (retire):** kod silinir. Deney olumsuz ya da etkisiz sonuçlandı veya başka bir çözüm onun yerini aldı. Geri getirmek için git geçmişi kullanılır.
  - Kaldırılan istemci anahtarı tanınmaz, sessizce yok sayılır ve `ignored` listesine de girmez.
  - Kaldırılan host değişkeni ortamda kalırsa her akış başında `W encoder ev=knob_ignored name= value=` yazılır (T-302; `EncoderKnobs.swift` `RemovedKnobs`). İstisna: `MATEBRIDGE_VD_TRANSFER` (T-304) sessizce yok sayılır.

**Derleme:** Mac uygulaması `scripts/bundle-host.sh` ile varsayılan olarak `release` derlenir (2026-10-08, karar 0037 eki; `--debug` isteğe bağlı). Host ortam değişkenleri iki derlemede aynı çalışır.

Kısaltmalar:
- `MA` = `client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt`
- `VR` = `…/client/video/VideoRenderer.kt`; `…/client/` = `client-android/app/src/main/kotlin/dev/matebridge/client/`
- `HE` = `host-mac/Sources/MateBridgeHost/Video/HEVCEncoder.swift`
- `EK` = `host-mac/Sources/MateBridgeCore/Video/EncoderKnobs.swift`
- `VS` = `host-mac/Sources/MateBridgeCore/Video/VideoSettings.swift`
- `TK` = `host-mac/Sources/MateBridgeCore/Session/TransportKnobs.swift`
- `SS` = `host-mac/Sources/MateBridgeHost/Session/SessionServer.swift`
- `N:` = `docs/NOTES.md` satırı

## Sayım (51e6b392)

| Taraf | Sayı | Komut |
|---|---|---|
| İstemci açılış parametreleri | 21 farklı anahtar (+4 `net_bench` alt anahtarı, + `dev` kapısı) | `DevKnobs.SPECS` (`…/session/DevKnobs.kt`). `MainActivity` ekstraları yalnız `LaunchExtras` üzerinden okur: `grep -rnoE 'get(Int\|String\|Boolean)Extra\(' client-android/app/src/main` → MA'daki genel okuyucu + aşağıdaki iki yayın alanı |
| Host ortam değişkenleri | 18 okunan `MATEBRIDGE_*` (+5 yalnız `RemovedKnobs.variables` listesinde) | `grep -rhoE '"MATEBRIDGE_[A-Z0-9_]+"' host-mac/Sources \| sort -u` → 23 |
| Host CLI kipleri | 6 | `host-mac/Sources/MateBridgeApp/main.swift` (`runIfRequested` çağrıları) + `FilesNetSelfTest.swift` (`--files-net-hold`) |

Sınıf dağılımı (canlı anahtarlar):
- İstemci: yalnızca geliştirici 18 (+4 alt anahtar), kalır 3. T-312 birleşirse +1 (`dec_out_park`, satır 23l).
- Host env: yalnızca geliştirici 15, kalır 3.
- CLI: kalır 6.

Kaldırılanlar (geçmiş satırları):
- İstemci: 2026-10-03 T-183/T-184 16 anahtar; 2026-10-08 T-295 2 (`dec_wait`, `aead_path`), T-300 9 (`tos_ctl`, `tos_video`, `wifi_ll`, `hz_pin`, `color_range`, `color_standard`, `color_transfer`, `dec_lowlat`, `dec_oprate`), T-303 1 (`jitter`).
- Host: 2026-10-03 T-186 2, T-204 9; 2026-10-08 T-302 5 (+ `MATEBRIDGE_CHROMA` değerleri `444`, `sharp_bilinear`), T-304 1.

Sayıma girmeyen okumalar (açılış parametresi değil ya da başka giriş noktası):
- MA `getBooleanExtra("connected")`: USB durum yayınının (`ACTION_USB_STATE`) alanı.
- MA `BatteryManager.EXTRA_PLUGGED`: pil yayını.
- `client-android/app/src/debug/…/bench/NetBenchActivity.kt`: MA'nın ilettiği `net_bench*` anahtarlarını okur (sayıldı).
- `VideoTestActivity` (`fps`, `full_range`, `primaries`): T-300 sildi.

## İstemci açılış parametreleri (21)

| # | Ayar | Varsayılan | Nerede (51e6b392) | Kart / kanıt | Sınıf | Sonuç | Uygulayan |
|---|---|---|---|---|---|---|---|
| 1 | `--ei jitter N` (sabit tampon `FramePacer`; Oyun `jitter 0` A/B'si) | — | — | T-016/T-052, T-210, T-211 | **Kaldırıldı (T-303, 2026-10-08)** | Yalnız uyarlamalı pacer kaldı; `ev=profile pacer=adaptive` sabit. 0026 §7 kapanır | T-303 |
| 2 | `--ei hz N` | -1 = akışı izler (`FrameRatePolicy.HZ_FOLLOW_STREAM`) | `…/session/DevKnobs.kt` (`hz`); MA (`targetHz`); `…/stream/FrameRatePolicy.kt` | T-046 | yalnızca geliştirici | 60/120 A/B için yararlı | T-185 |
| 3 | `--ei oprate 0/-1/-2/N` | — | — | T-052; N:315 | **Kaldırıldı (T-183, 2026-10-03)** | HiSilicon `KEY_OPERATING_RATE`'i kabul etmiyordu; varsayılan T-222'de `max` oldu | T-183 |
| 4 | `--es render gl`, `--ei frate`, `--ez glpts` (GL sunum yolu) | — | — | T-018; T-019 park; N:132-136 | **Kaldırıldı (T-184, 2026-10-03)** | HarmonyOS GL yüzeyini de 60 Hz'de tutuyordu; iki yüzey yaşam döngüsü riski | T-184 |
| 5 | `--ez stats_1s true` | false (10 s pencere) | `…/session/DevKnobs.kt` (`stats1s`); `…/stream/StatsLogWindow.kt` (`FAST_MS`) | T-141; N:1079-1083 | kalır (tanı) | Ölçüm koşuları için gerekli; varsayılan güç tasarrufu sağlar | — |
| 6 | `--ei inflight N` | — | — | T-057; N:342 | **Kaldırıldı (T-183, 2026-10-03)** | inflight 3/4 ölçümde daha kötüydü | T-183 |
| 7 | `--ei lead_us N` | yok = 6 ms | `…/video/VsyncClock.kt` (`DEFAULT_LEAD_NS`, `leadOverrideNs`) | T-057/T-061; N:352-354 | yalnızca geliştirici | Tarama sabit 6 ms'de bitti; OS güncellemesinden sonra yeniden ayar için kalır | T-185 |
| 8 | `--ei deadline_us N` | yok = 6 ms; -1 = ekranın bildirdiği | `…/video/VsyncClock.kt` (`DEFAULT_DEADLINE_NS`, `deadlineOverrideNs`) | T-071; N:388-393 | yalnızca geliştirici | 6 ms benimsendi; HarmonyOS 13,33 ms bildiriyor | T-185 |
| 9 | `--ez keep_jitter`, `--ez recenter` | — | — | T-067 | **Kaldırıldı (T-183, 2026-10-03)** | Sonuçsuz tek ölçüm; T-067 "yapılmayacak" kapandı | T-183 |
| 10 | `--es pacer cpd`, `--ei cpd_q_permille`, `--ei cpd_hold_us` | — | — | T-080; N:446-453 | **Kaldırıldı (T-183, 2026-10-03)** | Kullanıcı gecikmeyi hissetti. `tools/pacing/sim.py` kalır | T-183 |
| 11 | `--ez pace_trace true` | false | `…/session/DevKnobs.kt` (`paceTrace`); `…/video/PaceTrace.kt` | T-069/T-073/T-077 | kalır (tanı) | `tools/pacing` tekrar oynatma malzemesinin kaynağı. Kapalıyken tek bir volatile okuma | — |
| 12 | `--ez crypto_bench true` | — | — | T-076; N:421 | **Kaldırıldı (T-183, 2026-10-03)** | Tek seferlik: AndroidOpenSSL zaten varsayılan | T-183 |
| 13 | `--ez perf_hint`, `--ei perf_hint_target_us` | — | — | T-079; N:439 | **Kaldırıldı (T-183, 2026-10-03)** | HarmonyOS 4.3'te `createHintSession` oturum vermiyor | T-183 |
| 14 | `--ei ping_ms N` | 500 (20–1000) | `…/session/WifiKnobs.kt` (`WifiKnobs.parse`); log `wifi_knobs ping_ms=` | T-089 | yalnızca geliştirici | 3 s PONG zaman aşımı sözleşmesini koruyor; zararsız | T-185 |
| 15 | `--ei tos_ctl`, `--ei tos_video`, `--ez wifi_ll` (+ `WifiLockHolder`, `WAKE_LOCK`) | — | — | T-089, T-127; N:581-597 | **Kaldırıldı (T-300, 2026-10-08)** | T-127: `tos_ctl` ve `wifi_ll` uygulandı ama etkisiz, `tos_video` ölçülmedi. `WAKE_LOCK` izni de gitti | T-300 |
| 16 | `--ei rvote`, `--ei rvote_min_fps`, `--ei rvote_prio` | — | — | T-140; N:1072-1078 | **Kaldırıldı (T-183, 2026-10-03)** | Olumsuz: panel %100 60 Hz kaldı | T-183 |
| 17 | `--ez audio false` | true | `…/session/DevKnobs.kt` (`audio`); MA (`audioAllowed`) | T-095 | yalnızca geliştirici | Ayar ayrıca HELLO ses bitini düşürür (sesi yalıtmak için) | T-185 |
| 18 | `--es transport auto/usb/wifi` | kayıtlı ayar (değiştirilmez) | `…/session/DevKnobs.kt` (`transport`); MA `onCreate` | T-096 | yalnızca geliştirici | Tek açılışlık geçersiz kılma; USB/Wi-Fi A/B için yararlı | T-185 |
| 19 | `--es audio_out aaudio/track/auto` | kayıtlı ayar | `…/audio/AudioPlayout.kt`; `…/audio/SinkPolicy.kt` | T-100/T-101 | yalnızca geliştirici | Panel "Ses çıkışı" seçimini kaydetmeden yineler | T-185 |
| 20 | `--ei audio_buf_bursts N` | yok = AudioTrack 1, AAudio max(4, hatırlanan) burst; 1–6 | `…/audio/AudioBufferConfig.kt`; `…/audio/AudioPlayout.kt` | T-110/T-114 | yalnızca geliştirici | Geçersiz kılmadan sonraki büyüme öğrenilmiş duruma sızar (T-110); sıfırlama T-191'de | T-185, T-191 |
| 21 | `--ez quickack false` | true | `…/session/QuickAck.kt` | T-074; N:415-420 | yalnızca geliştirici | Varsayılan açık A/B ile kanıtlandı; kapatma A/B için kalır | T-185 |
| 22 | `--ez stall_diag true` | false | `…/diag/StallDetector.kt` | T-120/T-142; N:1088 | kalır (tanı) | Zaten isteğe bağlı | — |
| 23 | `--es net_bench host:port` (+ `net_bench_s`, `net_bench_dir`, `net_bench_streams`, `net_bench_rcvbuf_kb`) | yok; alt anahtarlar 8 s (1–600), `down`, 1 (1–4), işletim sistemi varsayılanı (≤ 65 536 KB) | `client-android/app/src/debug/…/bench/` (`NetBench.kt`, `NetBenchActivity.kt`, `NetBenchRunner.kt`); MA (`netBench` iletimi) | T-090 | yalnızca geliştirici; yalnız debug APK | `NWConnection` kök nedenini kanıtladı; nadiren gerekli. Daily APK'da `err=not_in_build` | T-185 |
| 23b | `--es decoder_fault create/configure/dequeue/silent`, `--ei decoder_fault_after_s N` | yok; 10 | `…/video/DecoderFault.kt` (`parseMode`, `DEFAULT_AFTER_S`); MA (`FLAG_DEBUGGABLE` kontrolü) | T-159 | yalnızca geliştirici; yalnız debug APK | Hata enjeksiyonu. T-301'den beri daily APK'da etkisiz | T-185 |
| 23c | `--ei game_display 0` | yok = "Oyun çözünürlüğü" ayarı (varsayılan 1848×1214); `0` = grup yok (0×0, doğal HiDPI ekran). Başka değerler yok sayılır | `…/session/DevKnobs.kt` (`gameDisplay`); `…/stream/GameMode.kt` (`GameModeSettings`) | T-215, karar 0029 | yalnızca geliştirici | Oyun ekranı ile doğal ekranın A/B'si (T-216). `ev=profile display=` alanında görünür | T-215 |
| 23d | `--es dec_lowlat off/hisi/vdec/all`, `--es dec_oprate fps/max` | — | — | T-217, T-222 | **Kaldırıldı (T-300, 2026-10-08)** | T-222 `oprate=max`'ı varsayılan yaptı, şimdi sabit. Configure/start hatasında akış fps'iyle tek yeniden deneme kalır (`dec_lowlat_rejected`) | T-300 |
| 23e | `--es dec_wait poll/event_in` | — | — | T-286 | **Kaldırıldı (T-295, 2026-10-08)** | `event_in` davranışı sabit (giriş döngüsü olaya kadar park eder) | T-295 |
| 23f | `--es aead_path legacy/direct` | — | — | T-292 | **Kaldırıldı (T-295, 2026-10-08)** | `direct` (doğrudan `ByteBuffer`) sabit | T-295 |
| 23g | `--es audio_idle_pause off/pause/stop` | yok = `pause` | `…/session/DevKnobs.kt` (`audioIdlePause`); `…/audio/IdlePause.kt`; `…/audio/AudioPlayout.kt` | T-287 | yalnızca geliştirici | 60 sn paket gelmezse AAudio çıkışını durdurur, ilk paketle başlatır (ilk ses +80 ms, sessizlikte `mb-audio` ~0 uyanma/s). Kullanıcı kararı: varsayılan `pause`; `off` hızlı kapatma anahtarı | T-287 |
| 23h | `--es hz_pin off/lp/all` | — | — | T-243; NOTES 2026-10-05 | **Kaldırıldı (T-300, 2026-10-08)** | Olumsuz. `render ev=stats hz_switches=` sayacı kalır | T-300 |
| 23i | `--es color_range`, `--es color_standard`, `--es color_transfer` | — | — | T-231; NOTES 2026-10-05 | **Kaldırıldı (T-300, 2026-10-08)** | Çözücü renk anahtarlarını yok sayıyor. `ev=decoder_output_format` kalır | T-300 |
| 23j | `--ei pace_dcap_half N`, `--ez pace_feedback false` | yok = `PacerTuning.STANDARD` (D tavanı n=1'de 2, n=2'de 3 yarım periyot; geri besleme açık). N 1–8 (üstü 8'e kırpılır, 1 altı yok sayılır) | `…/session/DevKnobs.kt` (`pacerTuning`); `…/video/PacerTuning.kt` (`PacerTuning.parse`); `VR` (`pacerTuning`) | T-251 | yalnızca geliştirici | 120-on-120 (n=1) atlama tanısı. Etkin değerler ilk `render ev=stats` satırında `pacer_knobs=`. Cihaz koşusu yapılmadı: açık nokta 4 | T-251 |
| 23k | `--ez catch_up false` | true | `…/session/DevKnobs.kt` (`catchUp`); `VR` (`catchUp`); `…/video/CatchUp.kt` | T-252 | yalnızca geliştirici | `false`: T-252 öncesi taşma yolu (boşalt + keyframe isteği) A/B için | T-252 |
| 23l | `--es dec_out_park off/on` | `off` | `…/session/DevKnobs.kt` (`decOutPark`); `…/video/OutputPark.kt`; `VideoRenderer.outPark` | T-312 | yalnızca geliştirici; A/B bekliyor | `on`: codec boşken çıkış iş parçacığı 5 ms yoklama yerine en çok 20 ms park eder; her parktan sonra mutlaka bir dequeue denemesi yapılır (donma yok). Boşta ~40 uyanma/s (bugünkü `IdleWait` ile aynı); kazanç düşük fps akışta. Benimsenirse varsayılan değişir | T-312 |
| 23m | `--ez cursor_predict false` | true | `…/session/DevKnobs.kt` (`cursorPredict`); MA (`predict = devKnobs.cursorPredict`); `…/cursor/CursorPredictor.kt` | T-278, karar 0036 v2 | yalnızca geliştirici | `false`: yerel imleç v1'deki gibi host konumunda çizilir | T-278 |

## Host ortam değişkenleri (18 canlı; kaldırılanlar geçmiş için)

Host'ta geliştirici kapısı yok. "Yalnızca geliştirici" burada: kalır, varsayılan dışı değeri `ev=profile` satırında görünür (T-204). İstisna: `MATEBRIDGE_REFINE*` `knobAllowList`'te yok (açık nokta 3).

| # | Ayar | Varsayılan | Nerede (51e6b392) | Kart / kanıt | Sınıf | Sonuç | Uygulayan |
|---|---|---|---|---|---|---|---|
| 24 | `MATEBRIDGE_FPS`, `MATEBRIDGE_BITRATE_KBPS` | tabletten türetilen fps (geçersiz değer 60); mod varsayılanı / STREAM_PREFS (5 000–150 000) | VS (`applyingExperimentKnobs`, `parseFps`, `parseBitrateKbps`); `host-mac/Sources/MateBridgeCore/Video/EncodeBench.swift` | T-045/T-086 | yalnızca geliştirici | Env bit hızı STREAM_PREFS'i ezer (`bitrate_source=env`). `MATEBRIDGE_FPS=120` sanal ekranı da 120 Hz kurar (T-302) | T-204 (profil) |
| 25 | `MATEBRIDGE_CODEC`; `MATEBRIDGE_H264_PROFILE` | `hevc`; — | VS (`parseCodec`); `EncodeBench.swift` | T-082/T-086; N:532 | CODEC: yalnızca geliştirici. H264_PROFILE: **Kaldırıldı (T-204, 2026-10-03)** | M6'da H.264 2800×1840@120'ye yetişmiyor (~24 ms); codec uyumluluk hata ayıklaması için kalır | T-204 |
| 26 | `MATEBRIDGE_REFRESH=60/120` | — | — | T-017 | **Kaldırıldı (T-302, 2026-10-08)** | Kural sabit: 60 Hz, fps 120 ise 120. Ortamda kalırsa `knob_ignored` | T-302 |
| 27 | `MATEBRIDGE_FRAME_DELAY=0/1` | — | — | T-017 | **Kaldırıldı (T-204, 2026-10-03)** | Ölü deney | T-204 |
| 28 | `MATEBRIDGE_ENCODER=llrc/fast` | — | — | T-053/T-087 | **Kaldırıldı (T-302, 2026-10-08)** | `fast` sabit (`encoder_profile=fast`); LLRC dalları silindi. Ortamda kalırsa `knob_ignored` | T-302 |
| 29 | `MATEBRIDGE_IDLE_REFRESH_MS`, `_COUNT`, `_KEY`, `_BUFFER`, `_QP` | — | — | T-086/T-087; N:562-579 | **Kaldırıldı (T-204, 2026-10-03)** | `fast` profil akış ortası QP'yi yok sayıyor; bench kazancı ısınma yanılgısıydı. `resubmitLast` kalır | T-204 |
| 30 | `MATEBRIDGE_PRIO_SPEED=0`; `MATEBRIDGE_QUALITY` | — | — | T-086; N:542 | PRIO_SPEED: **Kaldırıldı (T-204, 2026-10-03)**. QUALITY: **Kaldırıldı (T-302, 2026-10-08)** | PRIO_SPEED=0 ~25 ms kodlama. QUALITY benimsenmedi; `encoder_config quality=unset quality_applied=0` sabit kalır. Ortamda kalırsa `knob_ignored` | T-204, T-302 |
| 31 | `MATEBRIDGE_KEYFRAME_INTERVAL_S` | 300 (en çok 3600) | `host-mac/Sources/MateBridgeCore/Video/KeyframeIntervalPolicy.swift` (`resolve`) | T-075; N:420 | yalnızca geliştirici | 300 s benimsendi | T-204 (profil) |
| 32 | `MATEBRIDGE_INPUT_RETAG=0` | — | — | T-113; N:758-805 | **Kaldırıldı (T-204, 2026-10-03)** | Retag her zaman açık; `=0` bilinen bir renk/gecikme hatasını geri getirirdi | T-204 |
| 33 | `MATEBRIDGE_WIFI_BITRATE_KBPS` | — | — | T-088, T-178 | **Kaldırıldı (T-302, 2026-10-08)** | Wi-Fi varsayılanı T-178'de geldi; `bitrate_source=wifi_env` kalktı. Ortamda kalırsa `knob_ignored` | T-302 |
| 34 | `MATEBRIDGE_SERVICE_CLASS` | `signaling` | TK (`ServiceClassKnob.parse`) | T-088/T-124; N:958-959 | yalnızca geliştirici | `signaling` varsayılan olarak benimsendi | T-204 (profil) |
| 35 | `MATEBRIDGE_VIDEO_SOCKET=nw`, `MATEBRIDGE_CONTROL_SOCKET=nw` | — | — | T-091/T-092/T-111; N:620-643 | **Kaldırıldı (T-186, 2026-10-03)** | `NWConnection` Wi-Fi'de ~27 Mbps tavan. `ev=listening` alanları `bsd` sabit | T-186 |
| 36 | `MATEBRIDGE_NOTSENT_LOWAT_KB` | 128 (16–4096) | TK (`NotSentLowatKnob`) | T-091; N:643 | yalnızca geliştirici | H03 ayarı; 64/128/256 farkı gürültü düzeyinde | T-204 (profil) |
| 37 | `MATEBRIDGE_SENDQ_LOG`, `MATEBRIDGE_LAT_TRACE` | 0, 0 | TK (`SendQueueLogKnob`); `host-mac/Sources/MateBridgeHost/Video/LatencyCsv.swift` (`LatencyCsv.init`) | T-070/T-088, T-170, T-311 | kalır (tanı) | H03/H05/M07 izleri için gerekli. T-311: `latency.csv` sonuna `convert_us,bytes,key` | — |
| 38 | `MATEBRIDGE_TCP_LOG` | `auto` (yalnızca Wi-Fi) | `host-mac/Sources/MateBridgeCore/Session/TcpInfoLog.swift` (`TcpInfoLogKnob.parse`) | T-126 | kalır (tanı) | — | — |
| 39 | `MATEBRIDGE_AUDIO=off` | açık | `host-mac/Sources/MateBridgeCore/Audio/AudioStreamer.swift` (`AudioKnob.isDisabled`) | T-094 | yalnızca geliştirici | Yalıtım anahtarı | T-204 (profil) |
| 40 | `MATEBRIDGE_DISPLAY_KEEP_S` | 10 (10–86 400; geçersiz değer 10) | `host-mac/Sources/MateBridgeCore/Video/DisplayLease.swift` (`keepSeconds`, `keepUs`) | T-165 | yalnızca geliştirici | Bekletilen sanal ekranın süresi (duvar saati). Kullanıcıya açılan seçim T-167 (karar 0020, açık) | T-167 (menü) |
| 41 | `MATEBRIDGE_BITRATE_STEP=<kbps,…>@<n>s` (+ canlı bit hızı zinciri) | — | — | T-177 | **Kaldırıldı (T-302, 2026-10-08)** | Canlı bit hızı ayarlayıcısı ve `ev=bitrate_set` de silindi. Ortamda kalırsa `knob_ignored` | T-302 |
| 42 | `MATEBRIDGE_RATE_WINDOW_MS` | kapalı (10–999) | EK (`EncoderKnobs.parse`, `rateWindowMs`); `host-mac/Sources/MateBridgeCore/Video/EncoderSubmitOrder.swift` (`RateLimitWindows`) | T-177 | yalnızca geliştirici | Kısa `DataRateLimits` penceresi (kare boyutu tavanı). T-127 tetiği doldu; kaldırmadan önce **T-298 EN9** ölçümü bekleniyor (17/33/50 ms, Wi-Fi `cap_dec` p95) | T-298 EN9 sonrası karar |
| 43 | `MATEBRIDGE_VD_TRANSFER=0/1` | — | — | T-232; karar 0032 | **Kaldırıldı (T-304, 2026-10-08)** | HDR10 akış ekranı kendisi tf=1 ile kurar. Değişken sessizce yok sayılır (`knob_ignored` yok, `knobs=`'ta yok) | T-304 |
| 44 | `MATEBRIDGE_CHROMA=420/sharp_nearest/packed444` | yok/boş = tabletin `STREAM_PREFS.chroma`'sı (`1` → `sharp_nearest`, `2` → `packed444`, `0` → `420`) | `host-mac/Sources/MateBridgeCore/Video/ChromaMode.swift` (`ChromaKnob.parse`, `ChromaConfigLog`); `SharpYUVKernel.swift` (`sharp_fused`); `host-mac/Sources/MateBridgeHost/Video/ChromaConverter.swift`; HE | T-235, T-240, T-258; karar 0033, 0034 | yalnızca geliştirici | Geçerli değer tablet tercihinden önce gelir. Geçersiz değer ayarlanmamış sayılır, tablet tercihi kazanır (`chroma_config reason=invalid_value`). `444` ve `sharp_bilinear` **Kaldırıldı (T-302, 2026-10-08)**: geçersiz gibi davranır, ayrıca `knob_ignored`. `packed444` yalnız oturum onayıyla (HELLO bit11 + `chroma = 2` + Günlük 60), yoksa `sharp_nearest` (`reason=full_chroma_denied`). HDR10'da yok sayılır (`reason=hdr`). T-311: keskin yol tek Metal geçişi (`sharp_fused`), çıktı bit bit aynı | Karar 0033/0034: geliştirici geçersiz kılması olarak kalır |
| 45 | `MATEBRIDGE_VD_PRIMARIES=default/p3` | yok/boş = otomatik: HDR10 akışın sanal ekranı (`tf=1`) `p3`, SDR ekran primersiz; `default` = HDR'de de primersiz; geçersiz değer `p3` sayılır (`W ev=vd_transfer primaries_reason=invalid_value`) | `host-mac/Sources/MateBridgeCore/Video/VirtualDisplayPrimaries.swift` (`parse`, `logFields`); `host-mac/Sources/MateBridgeHost/VirtualDisplay.swift`; VS (`vdPrimariesKnob`) | T-281; karar 0032 güncellemesi | yalnızca geliştirici | Display P3 primerleri macOS'un ekranı geniş gamut saymasını ve Safari/YouTube HDR'yi sağlar (cihazda doğrulandı, 2026-10-06). `default`: A/B için | Varsayılan kalır, anahtar geliştirici aracı |
| 46 | `MATEBRIDGE_REFINE=0`, `MATEBRIDGE_REFINE_MS`, `_KB`, `_FRAMES` | açık; 200 ms (50–2000); USB 1024 KB, ağ 256 KB (16–8192); 16 kare (1–60). Geçersiz değer varsayılan | `host-mac/Sources/MateBridgeCore/Video/StillRefine.swift` (`StillRefineConfig.resolve`); `host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift` (çağıran); HE (`refineTick`) | T-253 | yalnızca geliştirici | Durağan ekran iyileştirme treni (`video ev=refine`). `REFINE=0` kapatma anahtarı, diğer üçü ayar. `ev=profile knobs=`'ta görünmez (açık nokta 3) | T-253 |

## Host CLI kipleri (6) ve derleme zamanı

| # | Ayar | Nerede | Kart | Sınıf | Sonuç |
|---|---|---|---|---|---|
| C1 | `--dump-video`, `--encode-bench`, `--sharpness-bench`, `--inject-test` | `host-mac/Sources/MateBridgeApp/main.swift` (`DumpVideoCommand`, `EncodeBenchCommand`, `SharpnessBench`, `InjectTestCommand`) | T-011/T-047/T-086/T-023 | kalır (araç) | Bench'ler host'taki tek tekrarlanabilir ölçüm. Ayrı bir çalıştırılabilir hedefe taşımak isteğe bağlı, kartı yok |
| C2 | `--files-net-selftest`, `--files-net-hold <port> <sn>` | `host-mac/Sources/MateBridgeApp/FilesNetSelfTest.swift` (`FilesNetSelfTest.runIfRequested`) | T-268 | kalır (araç) | Wi-Fi dosya yolunun loopback testi: pencere, Finder ve bağlama yok. `hold`: kendi WebDAV sunucusuyla komut satırından `mount_webdav` denemesi |
| — | `MATEBRIDGE_SIGN_IDENTITY` | `scripts/bundle-host.sh` (`identity=`) | T-006 | kalır (derleme zamanı) | Çalışma zamanı ayarı değil |
| — | `bundle-host.sh --debug` / `--release` | `scripts/bundle-host.sh` (`config=`) | T-305; karar 0037 eki | kalır (derleme zamanı) | Varsayılan `release` (2026-10-08); `--debug` isteğe bağlı |
| — | `install-apk.sh --debug` | `scripts/install-apk.sh` | T-301; karar 0037 | kalır (derleme zamanı) | Varsayılan debug olmayan `daily` APK; `--debug` debug APK (`run-as`, `decoder_fault`, `net_bench`) |
| — | `--ei draw_scale` | (yok) | T-144 geri alındı | zaten kaldırıldı | Ölç ve geri al örneği |

**Not (T-223, karar 0030):** Performans modu (%75 ölçek) kalktı ve ona bağlı bir geliştirici yolu bırakılmadı: istemci `scale_permille`'yi her modda 1000 gönderir (Ctrl+Shift+7 döngüsü Günlük → Çizim → Oyun). Ölçekli encode A/B'si gerekirse yeni bir ayar olarak, kendi kartıyla eklenir. Mod katmanı (Oyun/Çizim geçici varsayılanları) ve "Kare hızı" kullanıcı ayarlarıdır, açılış parametresi değil.

## Açık noktalar

1. **Jitter tamponu 1–2 dalı (0026 §7).** *Çözüldü (T-303, 2026-10-08):* `--ei jitter`, `FramePacer` ve Oyun `GameJitter` silindi; `VsyncClock` kendi dosyasında kaldı. Yalnız uyarlamalı pacer var.
2. **`VideoTestActivity` dışa açık.** *Çözüldü (T-300, 2026-10-08):* debug kaynak setinden silindi (önce T-185 `DUMP` izniyle korumuştu).
3. **`MATEBRIDGE_REFINE*` profil satırında yok.** `StreamProfileLog.knobAllowList` (EK) bu dört değişkeni içermiyor, bu yüzden varsayılan dışı değerleri `ev=profile knobs=`'ta görünmez (T-297 f). Kodu düzeltecek kart yok; orkestratör karar verir.
4. **`pace_dcap_half` / `pace_feedback` (T-251).** 120-on-120 cihaz koşusu hiç yapılmadı. Ya ölçüm planlanır ya da düğmeler kaldırılır (T-297 f "emin değil").

## Planlanan ayarlar

Geldiklerinde buraya satır eklenir; hepsinin varsayılanı kapalı:
- T-197: `ctl_lowat_kb` (`WifiKnobs.kt`'ye; dosya T-300'den beri yalnız `pingMs` taşıyor).
- T-198: `MATEBRIDGE_PEN_PLAYOUT_MS`.
- T-312: `--es dec_out_park` (satır 23l; dalda var, `main`'de yok).

Listeden çıkanlar: T-278 `cursor_predict` eklendi (satır 23m). T-196 `MATEBRIDGE_WIFI_ADAPT` uygulanmadı (2026-10-04, T-195 ile kapatıldı).
