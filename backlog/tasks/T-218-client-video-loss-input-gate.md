---
id: T-218
title: Gate input on video-only loss (stale picture must not keep input live)
status: review
phase: 6
owner: android-client-dev
depends_on: [T-159, T-160]
decisions: [0019]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionMachine.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionController.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoHealth.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/session/
  - client-android/app/src/test/kotlin/dev/matebridge/client/video/
  - docs/LOGGING.md
  - backlog/tasks/T-218-client-video-loss-input-gate.md
---

## Amaç

gpt-6-astra değerlendirmesi (docs/reviews/2026-10-04/astra-assessment.md, P1 #1): `VideoClosed` yalnız soketi kapalı işaretleyip yeniden bağlanmayı planlıyor; `VideoHealth`'i geçersiz kılmıyor, input'u bırakmıyor. Çalışan ama kare almayan decoder `no_output`/`not_running` kurallarını tetiklemiyor. Sonuç: video TCP bağlantısı kopar ve yeniden bağlanamazken kontrol PONG'ları sürerse, tablette son görüntü donuk dururken kalem ve klavye Mac'e gitmeye devam eder. Yarı açık video soketinde kurulu akış için okuma zaman aşımı da yok.

## Bağlam

- Kanıt: `SessionMachine.kt` ~:445, `VideoHealth.kt` ~:179, `MainActivity.kt` ~:618, `SessionController.kt` ~:884.
- İstenen: bilinen bir video kopması (VideoClosed, video soketi hatası) **hemen** input'u kapatır (mevcut `RELEASE_ALL(USER)` yolu) ve yeniden açılış yeni bir video kuşağının ilk çözülmüş çıktısını bekler (0019 STARTING kuralı).
- Belirsiz sessizlik (yarı açık soket): durağan masaüstünü bozuk video yolundan ayıran sınırlı bir canlılık denetimi. "N sn kare yok" kör kuralı **olmamalı** (0019 bunu reddetti). Aday: video bağlantısında host'un zaten ürettiği canlılık (ör. boşta keyframe/yeniden gönderim aralığı, `KEYFRAME_INTERVAL_S` 300 s) ya da video soketinde TCP keepalive/okuma zaman aşımı; kart ajanı mevcut mekanizmaları inceleyip en küçük güvenli çözümü önerir. Protokol değişikliği gerekiyorsa durup Açık sorular'a yazar.
- 0019 "healthy = decoder çıktısı"; sunum değil. Bu kart kapsamı genişletmez, yalnız video kaybı.

## Kabul kriterleri

- [x] [JVM] Sağlıklı oturumda VideoClosed → aynı tick'te input kapalı + bırakmalar; yeni video bağlantısının ilk çözülmüş çıktısına kadar kapalı.
- [x] [JVM] Video yeniden bağlanamazken kontrol PONG'ları sürse bile input kapalı kalır; "Görüntü durdu" katmanı gösterilir.
- [x] [JVM] Durağan masaüstü (kare yok, video soketi sağlam) yanlış alarm vermez.
- [ ] [device] Akış sırasında video bağlantısını kes (ör. host'ta video soketini kapat / tablette video portunu engelle): tablette katman, Mac'te takılı girdi yok, video dönünce input açılır.

## Plan

Mevcut canlılık incelemesi (kod okuması):
- Host durağan ekranda video soketine hiçbir şey yazmaz. Boşta keyframe (`HEVCEncoder.idleKeyframeNs` 1 sn) yalnız **bekleyen bir keyframe isteği** varken son tamponu yeniden kodlar; `KEYFRAME_INTERVAL_S` (300 sn) yalnız kare akarken geçerli. Yani host tarafında periyodik bir video canlılık sinyali yok.
- Host video soketi: `BsdTcpOptions` varsayılanı, `SO_KEEPALIVE` kapalı. Tablet video soketi: keepalive yok, okuma zaman aşımı yok (`SessionController.VideoConn`).
- T-160 `VideoDeliveryGate`: bir video bağlantısının ilk teslim edilen karesi (`video_gate_open`) belli. `abort()` (yeniden yapılandırma, oturum kaybı, göç) `closedPosted`'ı kurar, bu yüzden `VideoClosed` yalnız **beklenmeyen** kopuşta (EOF, IO/protokol hatası, bağlanamama, anahtar yok) gelir.
- T-205: kanıt beklenirken (`candAck != null`) eski videonun kapanması host'un devralmasından gelebilir, ama bunun kanıtı yok (Codex incelemesi, P1). Input kapısı bu durumda da hemen kapanır; yalnız katman bekleyebilir.

En küçük güvenli çözüm (protokol değişikliği yok):
1. **Bilinen kopuş → aynı anda input kapalı.** `SessionMachine`, STREAMING'de geçerli video kuşağının `VideoClosed`'ında yeni `Action.VideoLost(gen, duringMigration)` üretir. Bunu her zaman yapar, kanıt beklenirken de (`duringMigration = true`). Bu bayrak yalnız katmanı geciktirir: promosyon yoksa merdivenin ilk adımına (+1 sn) kadar. Makinenin `inputAllowed`'ı **değişmez**: kontrol bağlantısı açık kalır, bırakmalar (`RELEASE_ALL(USER)`) reddedilmez.
2. `SessionController`: `SessionListener.onVideoLost(gen)` (motor iş parçacığı) ve `onVideoFlowing(gen)` (yeni video bağlantısının ilk teslim edilen karesi, bağlantı başına bir kez).
3. `VideoHealth`: yeni `FaultCause.VIDEO_LOST` (`video_lost`). `videoLost()` → FAULT; mevcut yol input'u kapatır (`syncInputActive` → `RELEASE_ALL(USER)`), beslemeyi durdurur, "Görüntü durdu" katmanını gösterir, kurtarma merdiveni işler (+1/+3 sn decoder, +6 sn oturum, +15 sn "Yeniden dene"). `videoFlowing()`: FAULT(video_lost) iken RESTART_CODEC döner, yani yeni bir decoder kuşağı. Kuşak STARTING'dedir; ilk çözülmüş çıktısında HEALTHY olur (0019). Eski bağlantının kareleri kuyruk sıfırlamasıyla düşer.
4. **Belirsiz sessizlik (yarı açık soket):** tablet video soketinde TCP keepalive açılır (`SO_KEEPALIVE`, `TCP_KEEPIDLE` 3 sn, `TCP_KEEPINTVL` 1 sn, `TCP_KEEPCNT` 3). Ayar QuickAck gibi kopyalanmış fd üzerinden `Os.setsockoptInt` ile yapılır. Durağan masaüstünde Mac çekirdeği probu ACK'ler, yanlış alarm yok. Ölü ya da sıfırlanmış uçta okuma ≤ ~6 sn'de ETIMEDOUT/ECONNRESET ile biter ve olağan `VideoClosed` → 1. adım işler. Bu, kontrolün PONG zaman aşımından (3 sn) daha gevşektir. "N sn kare yok" kuralı yok. Ayar başarısız olursa yalnız loglanır, oturuma dokunmaz. Saf `VideoKeepalive` nesnesi sahte setter'la JVM'de test edilir.
5. JVM testleri: `SessionMachine` VideoLost (geçerli, eski, kanıt bekleme, aday başarısızlığı); `VideoHealth` (aynı çağrıda kapanma, PONG'lar sürerken kapalı kalma + katman, akış dönünce yeniden başlatma ve ilk çıktıda açılma, durağan masaüstü); keepalive ayarları.
6. `docs/LOGGING.md`: `cause=video_lost`, `video_recover step=resume`, `ev=video_keepalive`.

Kapsam dışı (Açık sorular'a): host video hattı canlı ama takılı (Mac çekirdeği ACK'ler) durumu; USB (`adb reverse`, loopback) üzerinde keepalive yerel uca gider.

## Handoff

- **Commit:** `105891c` (kod + testler + LOGGING). Plan `2d49e82`. Codex P1 düzeltmesi ayrı bir commit'te (bkz. aşağı). Dal `task/T-218-client-video-loss-input-gate`. `./scripts/check.sh`: ALL OK.
- **Codex (--high) P1 düzeltmesi:** İlk sürüm, göç kanıtı beklenirken (`candAck != null`) `VideoLost`'u bastırıyordu. Kanıt takılır ve geçerli video bağımsız olarak koparsa, input donuk görüntüde 3 sn'ye kadar açık kalıyordu.
  - Şimdi geçerli videonun her kopuşu input'u hemen kapatır. Bırakmalar geçerli kontrol bağlantısından gider.
  - `duringMigration` yalnız katmanı geciktirir (`VideoHealth.quietOverlay`). Katman şu durumlarda açılır: merdivenin ilk adımında (+1 sn), göç dışı bir kopuşta ya da başka bir hatada. Görüntü HEALTHY olursa bayrak temizlenir. Açık bir kurtarma bölümündeyse katman hiç gizlenmez.
  - Ertelenmiş bildirim (`videoLostDeferred`) kaldırıldı.
  - Regresyon testi: `MigrationAuthGateTest.currentVideoLossDuringAStalledProofGatesInputAtOnce`.
- **Dokunulan dosyalar:**
  - `session/SessionMachine.kt`: `Action.VideoLost(gen, duringMigration)`.
  - `session/SessionController.kt`:
    - `SessionListener.onVideoLost` / `onVideoFlowing`, `exec(VideoLost)` + `ev=video_lost`.
    - `VideoConn`: `video_gate_open` noktasında `onVideoFlowing`, connect sonrası `VideoKeepalive.forSocket`.
    - Dosya sonunda yeni `object VideoKeepalive`.
  - `video/VideoHealth.kt`: `FaultCause.VIDEO_LOST`, `videoLost(quietOverlay)`, `videoFlowing()`.
  - `MainActivity.kt`: iki listener override'ı (UI thread'e geçer).
  - Testler:
    - yeni: `session/VideoLossGateTest.kt` (makine + VideoHealth + gerçek `InputCapture`/`FakeSink` host modeli), `session/VideoKeepaliveTest.kt`;
    - güncellenen: `video/VideoHealthTest.kt` (+10 test, neden listesi). `session/MigrationAuthGateTest.kt`: kanıt beklenirken `VideoClosed` artık `VideoLost(duringMigration = true)` verir; ayrıca yeni regresyon testi.
  - `docs/LOGGING.md`.
- **Varsayımlar:**
  - `VideoClosed` yalnız beklenmeyen kopuşta gelir: `abort()` `closedPosted`'ı kurduğu için yeniden yapılandırma, oturum kaybı ve göç onu üretmez (mevcut kod).
  - Makinenin `inputAllowed`'ı bilerek değişmedi. Kapı `VideoHealth` → `syncInputActive` → `capture.setActive(false)`, yani `RELEASE_ALL(USER)`. Kontrol bağlantısı açık olduğu için bırakmalar gider; tel değişmez.
  - Video dönünce `videoFlowing` → `restartCodec()`: kuyruk sıfırlanır, `KEYFRAME_REQUEST(STARTUP)` gider. Eski bağlantının kodek içindeki kareleri yeni kuşağın ilk çıktısı sayılamaz.
  - Video hiç dönmezse mevcut 0019 merdiveni işler: +1/+3 sn decoder, +6 sn oturumu yeniden kurma, +15 sn "Yeniden dene". `resume` merdivenin sonraki adımını bir tam aralık öteler.
  - Keepalive sabitleri (3 s / 1 s × 3) Linux `tcp.h` numaralarıyla, QuickAck'teki gibi kopyalanmış fd üzerinden ayarlanır. HarmonyOS 4.3 Linux çekirdeği varsayıldı. Başarısızlık yalnız `ev=video_keepalive ok=0` yazar.
- **Test edilmeyenler / cihazda doğrulanacaklar** (orkestratör, tek tek):
  1. Akışta tablette `adb logcat -s 'MB:*'` içinde her video bağlantısında `ev=video_keepalive ok=1 idle_s=3 intvl_s=1 cnt=3` görülmeli; `ok=0` olmamalı (setsockopt HarmonyOS'ta çalışıyor mu).
  2. Wi-Fi akışında host'ta yalnız video soketini kapat (ör. video portuna giden bağlantıyı `pfctl` ile kes ya da host'ta video bağlantısını zorla kapat), kontrol açık kalsın. Bu sırada bir tuşu basılı tut ve kalemle çiz. Beklenen: `W video_lost` + `video_health state=fault cause=video_lost`, "Görüntü durdu" katmanı, Mac'te takılı tuş/kalem yok (`RELEASE_ALL reason=USER`).
  3. Video dönünce: `video_gate_open` → `video_recover step=resume` → `state=starting` → ilk çıktıda `state=healthy`; input tekrar açılır.
  4. Durağan masaüstü (Mac'te hiçbir şey değişmesin) ≥ 2 dk: `video_lost` / `fault` yok, input açık. Keepalive probları ACK'lenmeli.
  5. Yarı açık soket (isteğe bağlı): video akışı sırasında Mac tarafında video akışının paketlerini sessizce düşür (`pfctl block drop` yalnız video portu, RST yok). ~6 sn içinde `video_lost` beklenir. Kontrol de etkilenirse bunun yerine oturum kaybı (PONG 3 sn) görülür; bu da doğru.
  6. USB↔Wi-Fi göçü (T-205). Eski video kanıt beklenirken koparsa logda `video_lost migrating=1` ve `video_overlay quiet=1` görülür; input kısa süre kapanır. Promosyon 1 sn içinde yeni kuşağı HEALTHY yaparsa "Görüntü durdu" katmanı hiç görünmemeli. Göç sonrası Mac'te takılı tuş ya da kalem kalmamalı.
- **Açık sorular:**
  - Host video hattı canlı ama takılı (encoder/SCK asılı, soket açık): Mac çekirdeği keepalive'ı ACK'ler, tablet bunu ayırt edemez. Bu kart kapsamında değil (astra P2 #4 / host liveness). İstenirse protokol değiştirmeden bir aktif prob yapılabilir: sessizlikte seyrek `KEYFRAME_REQUEST` gönderilir, host `resubmitNow` ile yanıt verir. Ama bu durağan ekranda periyodik IDR (bant/pil) demek. Ürün kararı gerekir, uygulanmadı.
  - USB (`adb reverse`, 127.0.0.1): keepalive probları tabletteki adbd'ye gider. Yarı açık bir USB video soketini keepalive yakalamaz. Tünel düşünce adbd yerel soketi kapatır, bu bilinen kopuş yoluna (`video_lost`) girer.
  - Host video soketi `SO_KEEPALIVE` kapalı; host yarı açık tablet soketini kendi tarafında fark etmez. Kapsam dışı (host-mac).
  - Kabul kriteri [device] doğrulanmadı (tablet yok); yukarıdaki 2–6.
