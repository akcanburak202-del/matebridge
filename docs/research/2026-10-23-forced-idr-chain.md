# Zorunlu IDR zinciri: Wi-Fi radyo kaybından sonra 0,2–0,4 sn donma (T-369)

Tarih: 2026-10-23. Yalnız araştırma/tasarım; kod değişmedi. Kanıt: `docs/NOTES.md` 2026-10-23 "öğleden sonra" ve iki "akşam" bölümü. Host günlüğünden yalnız özet sayılar alındı (ham satır yok).

## Özet

- Tetikleyici radyo kaybı, ama donmayı **bizim host kuyruğu** üretiyor: tek retx `snd_cwnd`'yi 284 KB → 48 KB düşürür; yavaşlayan bağlantıda 2 karelik kuyruk taşar; taşan delta zinciri kırar; zincir IDR ile onarılır; 490–880 KB'lık IDR daralmış bağlantıda yine 2+ kare aralığı boyunca yazılır; kuyruk yine taşar. Döngü kendini besliyor.
- Kök neden: kodlayıcıya kare vermek **aşağı akıştaki doluluğa bakmıyor** (`slotFree` yalnız VideoToolbox içindeki kareleri sayıyor). Kare kodlandıktan sonra kuyrukta düşürülüyor; oysa kodlamadan önce düşürmek (FramePacer `overwritten`) referans zincirini bozmaz.
- LTR/intra refresh bu Mac'te **yalnız** `EnableLowLatencyRateControl` oturumunda var; o mod repo ölçümüne göre 9–13 ms/kare ve ~100 fps tavanlı (HEVCEncoder.swift:196-199 yorumu). Şimdilik elenir.
- Öneri: önce kodlayıcı girişinde geri basınç (A, protokol değişmez), sonra gerekirse IDR arkasındaki delta'ları sınırlı tutma (D). Ölçüm `stall-inject.sh` ile.

## 1. Zincir (halka halka)

Yol: `host-mac/Sources/` altında.

1. **Gönderim kapısı.** `SocketVideoTransport.canSend` (`MateBridgeCore/Video/SocketVideoTransport.swift:50-63`): yazılmakta olan kayıt yok (`maxRecordsInFlight = 1`, :13) ve çekirdekte gönderilmemiş bayt < `TCP_NOTSENT_LOWAT` (128 KiB, 0023) ve isteğe bağlı `admission` (T-328). `VideoSender.run` yalnız `canSend` iken kare alır (`MateBridgeCore/Video/VideoSender.swift:202`; paketli yol :123).
2. **Kare akışı kapıya bakmaz.** `HEVCEncoder.maxInFlight = 2` (`MateBridgeHost/Video/HEVCEncoder.swift:81`); `EncoderSubmitOrder.offerChecked` `slotFree = inFlight < maxInFlight` (`MateBridgeCore/Video/EncoderSubmitOrder.swift:248`) yalnız VT içindekini sayar. Kuyruk/aktarım doluluğu girişe geri dönmüyor. Kodlanmış kare `frames.push` ile kuyruğa gider (`MateBridgeHost/Video/VideoPipeline.swift:153`).
3. **Taşma = zincir kırılması.** `BoundedFrameQueue.push` (`MateBridgeCore/Video/BoundedFrameQueue.swift:48-93`): kapasite 2 (:21); taşınca en eski korumasız kare atılır (:68-72); ardındaki delta'lar temizlenir (:81-85); arkada IDR yoksa `keyframeNeeded` + `awaitingKeyframe` (:86-89). `awaitingKeyframe` iken yeni delta'lar **reddedilir** (:50-57, `refusedCount`), yani IDR gelene kadar kuyruğa giren her şey düşer (günlükteki `queue_drops` 9–12/s bunun toplamı).
4. **Bildirim.** `VideoFrameQueue.push` → `keyframeNeeded()` (`MateBridgeCore/Video/VideoFrameQueue.swift:48-64`); `VideoPipeline.init` bunu `EncoderBox.queueDropped` yapar (`MateBridgeHost/Video/VideoPipeline.swift:119`, :554-557).
5. **Karar.** `decide` (:569-577) → `KeyframeRequestCoalescer.hostDrop` (`MateBridgeCore/Video/KeyframeRequestCoalescer.swift:167`) → `evaluateHost` (:208) / `coveredUntil` (:226). IDR zorlanmaz: kodlayıcıda/kuyrukta/yazılıyorsa veya son yazımdan `defaultWindowUs` = 250 ms (:31) geçmediyse; kesin üst sınır `defaultPendingTimeoutUs` = 1 sn (:34).
6. **Zorlama.** `HEVCEncoder.requestKeyframe(resubmitNow:)` (`MateBridgeHost/Video/HEVCEncoder.swift:520`) → `EncoderSubmitOrder.requestKeyframe` (:270); sonraki submit `ForceKeyFrame` taşır (:427-428); `resubmitNow` son yakalamayı hemen yeniden kodlar.
7. **Pencere 250 ms, IDR yazımı ondan uzun.** (Çıkarım, günlükle uyumlu.) 490 KB IDR, cwnd ~48 KB / ssthresh ~18 KB ile onlarca RTT (RTT 7–12 ms) sürer; bu sürede 60 fps'te ≥ 2 kare kuyruğa girer → halka 3 yine tetiklenir. IDR yazımı bitince + 250 ms sonra yeni IDR: ~2–3 IDR/sn. Günlük örneği (olay, ham değil): kayıp saniyesinde `retx=1`, `snd_cwnd` 48 KB; sonraki 3 sn'de `idr` = 3 / 3 / 1, gönderilen kare 4 / 3 / 50, `cap_dec` 230 / 434 / 24 ms, `queue_drops` 12 / 9 / 0. İstemci `keyframe_request` sayısı bu pencerede **0**: tüm IDR'ler host kaynaklı. 20 dk'da 74 IDR (39 saniyede ≥ 1; NOTES: oturumda 82).
8. **Başka IDR kaynakları (bu olayda baskın değil).**
   - Aktarım kareyi reddetti: `VideoSender.swift:155` (paketli), :215 (normal); en sık 500 ms'de bir (:236-243) → `VideoPipeline.requestKeyframe` (:334-338, her zaman zorlar).
   - İstemci `FRAMES_DROPPED`: `client-android/.../video/FrameQueue.kt:202,233,316` → `handleKeyframeRequest` (`VideoPipeline.swift:361-401`), 250 ms/1 sn kurallarıyla birleştirilir.
   - Yeni tüketici: `prepareForNewConsumer` (:411-418). Periyodik: 300 sn (`KeyframeIntervalPolicy.swift:10`).
   - `MATEBRIDGE_WIFI_ADAPT`: kapı reddi → kuyruk düşüşü → aynı zincir; NOTES "akşam ilk deneme" döngüyü büyüttü.
9. **`overwritten` zinciri kırmaz.** `FramePacer` yakalamayı **kodlamadan önce** değiştirir (`MateBridgeCore/Video/FrameGate.swift:133`, `takeOverwritten`); VT'ye giren kare akışında delik oluşmaz. Zinciri yalnız halka 3 (kodlanmış kare düşürme) ve halka 8 kırar. (Kod okumasından; birim testle doğrulanmadı.)
10. **Kodlayıcı yapısı.** `AllowFrameReordering = false` (`HEVCEncoder.swift:236`), B kare yok; `EnableLowLatencyRateControl` yok (:196-199). Her P bir öncekine bağlı varsayılır; VT'nin P referans sayısı **dokümante değil** (doğrulanmadı): bir P düşerse sonrakilerin bozulacağı kabulüyle tasarlandı. `DataRateLimits` 2x ortalama, 1 sn pencere (:249, :392): 490 KB'lık IDR bu sınırın çok altında, yani tavan IDR'yi küçültmez.

## 2. Birincil kaynak bulguları

- **VT başlığı** (`VideoToolbox.framework/Headers/VTCompressionProperties.h`, Xcode 27.1 SDK): `kVTCompressionPropertyKey_EnableLTR`, `kVTEncodeFrameOptionKey_AcknowledgedLTRTokens`, `kVTEncodeFrameOptionKey_ForceLTRRefresh`, `kVTSampleAttachmentKey_RequireLTRAcknowledgementToken` (macOS 12+). Akış: kodlayıcı her LTR çerçeveye jeton verir; istemci (alıcı) aldığını host'a bildirir; host jetonları sonraki karelere verir; kodlayıcı P'yi onaylı LTR'ye bağlar; onaylı LTR yoksa IDR üretir. Yani **alıcıdan host'a geri bildirim şart**.
- **Gerçek HW HEVC oturumunda yoklama** (bu Mac, 1848×1214, geçici sonda, depoya girmedi): mevcut ayarla (yalnız `EnableHardwareAcceleratedVideoEncoder`) `EnableLTR` **desteklenen özelliklerde yok** ve `VTSessionSetProperty` `-12900` (not supported) döner. Aynı oturum `EnableLowLatencyRateControl` ile açılınca `EnableLTR` ve `ReferenceBufferCount` listede, set `noErr`; ek olarak belgesiz `PeriodicRefreshMode` ve `MaxRefreshFrameIntervalDuration` görünüyor (açıklama başlıkta yok → belgesiz, kullanım doğrulanmadı). Başlık da low-latency modu "temporal layer yapısı, sonsuz GOP, B yok" diye tanımlar.
- **Düşük gecikmeli modun maliyeti:** repo ölçümü: bu mod + RealTime 2800×1840'ta kare başına ~9–13 ms, ~100 fps tavan (HEVCEncoder.swift:196-199 yorumu, T-047/T-053). Güncel 1848×1214 için yeniden ölçülmedi (doğrulanmadı).
- **Intra refresh:** VT'nin herkese açık başlığında "intra refresh" anahtarı yok (başlıklarda arandı, bulunamadı). Belgesiz `PeriodicRefreshMode` olası ama **doğrulanmadı**.
- **Android MediaCodec:** `developer.android.com/reference/android/media/MediaFormat` sayfası araçla okunamadı (sayfa 335 KB, sonuç menü metni döndü). Bu yüzden şu iddialar **doğrulanmadı**: `KEY_INTRA_REFRESH_PERIOD` ve `KEY_LTR_*` anahtarlarının yalnız kodlayıcı tarafı olduğu (bellekten); çözücü tarafında LTR/intra refresh için bir MediaFormat ayarı bilinmiyor. HEVC standardı uzun dönem referansı bit akışında (RPS) taşır; Kirin donanım çözücüsünün bunu doğru çözdüğü **doğrulanmadı** ve cihazda ayrı sınanmalı. `KEY_LOW_LATENCY` istemcide zaten kullanılıyor (`VideoRenderer.kt:408`).

## 3. Seçenekler

| # | Seçenek | Protokol (PROTOCOL.md) | İstemci | Beklenen etki | Risk |
|---|---|---|---|---|---|
| A | **Kodlayıcı girişinde geri basınç:** kuyruk+aktarım doluyken yeni yakalamayı VT'ye verme, pacer'da ez (kodlamadan önce düşürme, zincir kırılmaz) | Değişmez | Yok | Kök halkayı (3) kapatır: radyo kaybında fps geçici düşer (yakalama atlanır) ama IDR yok, 490 KB patlaması yok. Tahmin: olay başına IDR 3–7 → 0–1 | Orta-düşük. `slotFree` tanımı değişir (EncoderSubmitOrder). Atlanan karelerden sonra P büyür. Kuyruk+VT içi sayımı yanlışsa gecikme artar/kare aç kalır. Birim test mümkün (saf mantık) |
| B | (a) Düşen P referans değilse IDR yok | Değişmez | Yok | **Uygulanamaz:** P'ler zincir (§1.10), VT referans yapısı kontrol edilemiyor (`ReferenceBufferCount` yalnız LL modunda) | Yüksek yanlış pozitif = bozuk görüntü |
| C | (b) IDR'yi küçült: `MaxAllowedFrameQP`, `ForceKeyFrame` yerine yavaş tazeleme | Değişmez | Yok | QP tavanı kaliteyi bozar, IDR boyutu hâlâ ~4 P. Yavaş tazeleme (intra refresh) VT'de herkese açık yok; belgesiz `PeriodicRefreshMode` denenebilir ama doğrulanmadı | QP'de görsel kayıp; PeriodicRefresh belgesiz, LL modu gerekebilir |
| D | **(d) IDR arkasındaki delta'ları sınırlı tut:** yazılmakta/bekleyen bir IDR'nin arkasına gelen delta'lar zinciri bozmaz; taşmada zinciri kırmadan N kareye/≈150 ms'ye kadar kuyruğa izin ver, aşılırsa bugünkü davranış | Değişmez | Yok (istemci gecikmiş kareleri hızlı çözüp en yenisini gösterir; doğrulanmalı) | IDR yazımı sırasındaki "taşma → ikinci IDR" döngüsünü keser; gecikme IDR süresi kadar artar (≈0,2 sn) ama donma ve ikinci IDR yok | Orta. "Newest wins" kuralı (AGENTS.md) bu pencerede gevşer → karar kaydı (0023 eki) gerekir. Gecikme p99 ↔ donma takası |
| E | (e) Ardışık IDR'yi sınırla (ilk IDR teslim edilmeden yenisini isteme) | Değişmez | Yok | **Büyük kısmı zaten var:** 250 ms pencere + 1 sn üst sınır + `keyframeAheadSinceUs` (KeyframeRequestCoalescer). Pencereyi "yazımdan sonra 250 ms"den "yazım+cwnd'ye göre" yapmak ikinci IDR'yi geciktirir ama kuyruk taşması sürdükçe zincir kırık kalır → donma uzar | Düşük; kazanç belirsiz |
| F | (f) `DataRateLimits`ı kısa pencereye indir (IDR boyunu sınırla) | Değişmez | Yok | Başlık: sert tavan, kodlayıcı aşmaz. Kısa pencerede IDR kalitesi düşer, K kare artefakt; `MATEBRIDGE_RATE_WINDOW_MS` zaten var (diagnostik) | Kalite; T-298 EN9 ölçümü bekliyordu |
| G | (c) LTR: jetonlu onaylı referans, kayıpta IDR yerine LTR'ye bağlı P | **Değişir:** yeni istemci→host `LTR_ACK` mesajı, PROTOCOL.md + fixture + Swift/Kotlin | Çözücü LTR akışını çözmeli (Kirin: doğrulanmadı); ACK gönderimi | En küçük kurtarma (P boyutunda). | **Yüksek:** `EnableLowLatencyRateControl` zorunlu (9–13 ms/kare, ≤100 fps), ek mesaj (LTR_ACK), çözücü belirsiz, 3 Codex turu. Şimdi önerilmez |

Not: H (aktarım): kapıyı gevşetmek (`TCP_NOTSENT_LOWAT` ↑) kuyruk gecikmesini artırır, IDR sorununu çözmez; kapsam dışı.

## 4. Ölçüm planı (T-366 aracı)

Araç: `tools/measure/stall-inject.sh` (sudo, orkestratör + kullanıcı; ajan çalıştırmaz) ve `game_ab.py` olay raporu. Tarif: `tools/measure/README.md` tarif 6.

- **Kol düzeni:** host = mevcut `main` (taban) ve host + A (ve D varsa ayrı kol). 60 Mbps, Oyun 60, 1848, Wi-Fi, aynı sahne (TotK menüsüz sabit bir sahne ya da `dump`-benzeri tekrar edilebilir hareket). Kollar dönüşümlü, kol başına 100 sn, 10 sn'de bir 60 ms takılma → kol başına ~9 olay. En az 3 tekrar (≈27 olay/kol). Ek koşul: 200 ms takılma (IDR yazımı > 2 kare aralığı senaryosu) ve 30 Mbps kolu.
- **Not:** `dnctl` bant genişliğini ~0 yapar; gerçek radyo kaybındaki `cwnd` çöküşünü (retx) birebir üretmez. Taban kolunda donma görünmezse (cwnd düşmediği için), önce tabanın sorunu yeniden ürettiğini doğrula; üretmiyorsa takılmayı retx üretecek biçimde (kısa kayıp `plr`) genişletmek ayrı iş.
- **Ölçütler (olay penceresi 5 sn + 30 sn'ye kadar toparlanma):**
  1. olay başına IDR sayısı (`idr`): taban beklenen 3–7; hedef medyan ≤ 1;
  2. en büyük `cap_dec_ms`: taban 200–440; hedef ≤ 100 (A) ve p95 < 150;
  3. toparlanma süresi (`cap_dec_ms` < 30 ms'ye dönüş): hedef ≤ 1 sn (taban 3–5 sn);
  4. olay penceresinde alınan fps minimumu (taban 3–20): hedef ≥ 30;
  5. `queue_drops` + `refused`/olay (A'da ≈ 0 olmalı), `overwritten` artışı (A'da arttığı beklenir);
  6. yan etki: durağan 60 fps'te `cap_dec` p50/p99 ve `gate_wait` değişmemeli (A'nın sağlıklı koşulda etkisiz olduğunu göster).
- **Başarı:** 3 tekrarda tüm kolların medyan ve en kötü olay ölçütleri hedefte; sağlıklı koşulda regresyon yok.
- Cihaz koşusu tek seferde, paralel ajanla değil (CLAUDE.md).

## 5. Öneri

Sıra:

1. **T-370 (önerilen ilk kart, host, protokol yok): kodlayıcı girişinde geri basınç (A).** Kuyruk+aktarım doluyken `EncoderSubmitOrder` yeni kareyi VT'ye vermez, pacer'da ezer. Saf mantık, birim test (taşma senaryosu: IDR yazılırken 60 fps girdi → `keyframeNeeded` çağrılmaz). Kabul: §4 ölçütleri. Codex incelemesi (girdi/akış dokunuşu değil ama zincir kuralı; `--high` değil `medium`).
2. **T-371 (küçük, host): neden günlüğü.** `ev=idr_forced cause=queue_overflow|transport_refused|client_request|periodic|consumer` (+ `refused`). Bugün host kaynaklı IDR yalnız `idr=` sayısı olarak görünüyor; ölçüm A/B için gerekli. Önce yapılabilir (T-370 ile paralel).
3. **T-372 (koşullu, T-370 ölçümünden sonra): D, IDR arkasında sınırlı delta tutma** + karar kaydı (0023 eki, "newest wins" istisnası). Yalnız A sonrası olay başına IDR > 1 veya toparlanma > 1 sn kalıyorsa. Kullanıcıya gecikme ↔ donma takası sorulmalı.
4. **T-373 (araştırma, düşük öncelik): LTR/PeriodicRefresh uygulanabilirlik.** Önce düşük gecikmeli modun 1848×1214'te ücretini ölç; sonra Kirin çözücüsünde LTR akışı sınaması. Ancak ikisi de olumluysa protokol önerisi (`LTR_ACK`).
5. E ve F ayrı kart açılmaz; A/D ölçümünde artık sorun kalırsa F (`RATE_WINDOW_MS`) T-298 EN9 ile birlikte yeniden değerlendirilir. B elenir, C bekletilir (belgesiz API).

`MATEBRIDGE_WIFI_ADAPT` yeniden denemesi A'dan sonra yapılmalı: denetleyicinin kendi tetikleyicisini besleyen IDR döngüsü A ile büyük ölçüde kesilir (NOTES "akşam ilk deneme").

## 6. Doğrulanmamış / açık

- VT HEVC P referans sayısı ve düşen P'nin sonrakilere etkisi (belgesiz; kabul: zincir).
- 1848×1214'te low-latency modun maliyeti (eski ölçüm 2800×1840).
- `PeriodicRefreshMode` / `MaxRefreshFrameIntervalDuration` anlamı.
- Android `MediaFormat` LTR/intra-refresh anahtarları ve Kirin çözücüsünün LTR davranışı (doküman sayfası okunamadı).
- `dnctl` takılması gerçek radyo kaybındaki cwnd çöküşünü ve `retx`i üretiyor mu (taban kolunda doğrulanmalı).
- Halka 7'deki IDR yazım süresi hesabı günlüğe dayalı çıkarım; IDR başına `writeStart→writeDone` doğrudan ölçülmedi (LatencyTrace'te var; T-371 ile görünür yapılabilir).
- Aux (paketli tam renk) akışı bu analizde yok; ayrı kuyruk/koalesör aynı kalıbı taşır (`VideoPipeline.swift:128`).
