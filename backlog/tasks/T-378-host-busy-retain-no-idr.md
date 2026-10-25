---
id: T-378
title: Host — video yazımı geçici `.busy` reddinde kareyi tut ve yeniden dene; tek toparlanma kuşağı (astra öneri 2)
status: review
phase: 7
owner: mac-host-dev
depends_on: [T-370, T-371]
decisions: [0023]
files:
  - host-mac/Sources/MateBridgeCore/Video/
  - host-mac/Sources/MateBridgeHost/Video/
  - host-mac/Tests/MateBridgeCoreTests/
  - docs/LOGGING.md
  - host-mac/Sources/MateBridgeHost/Session/SessionServer.swift
  - host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift
  - host-mac/Sources/MateBridgeCore/Video/EncoderSubmitOrder.swift
  - backlog/tasks/T-378-host-busy-retain-no-idr.md
---

## Amaç

`docs/reviews/2026-10-25/astra-wifi-game.md` öneri 2. `VideoTransport.send` sonucu `Bool`'a indirgeniyor; `VideoSender` her reddi keyframe isteğine çeviriyor. 23 Ekim akşamı (T-370 sonrası) 5 zorunlu IDR'ın nedeni `transport_refused` idi. Geçici `.busy` bir kayıp değil: kare tutulup yeniden denenebilir, referans zinciri bozulmaz.

## Kabul

1. Gönderim sonucu türlü (ör. `accepted / busy / failed`). `.busy`: aynı kodlanmış kare tutulur ve hazır olunca yeniden denenir; `seq` ilerlemez, keyframe istenmez. Gerçek hata (yazım/şifreleme/geçersiz) bugünkü yoldan gider.
2. Tutulan kare aşağı akış ayrılmasında (T-370 `inFlight + queued`) sayılır; hesapsız ek yuva yok, kuyruklar sınırlı kalır.
3. Tek etkin toparlanma kuşağı: bir IDR yoldayken (kodlayıcı, kuyruk ya da soket) gelen yeni keyframe istekleri birleştirilir (`idr_coalesced`). `forceKeyframe`/`pendingBypass` kareleri hesaba katılır, tekrar tekrar kaçmaz. Yoldaki IDR takılırsa bugünkü sınırlı hata/yeniden bağlanma yolu kullanılır, zamanlayıcı yüzünden ikinci IDR üretilmez.
4. Yazımı kısmen yapılmış şifreli kayıt hiçbir zaman bırakılmaz ya da yeniden sıralanmaz.
5. Log: `idr_forced cause=` yanına red alt türü (`busy|write|seal|invalid`); `ev=send_retry` sayaçları saniyelik özete. LOGGING.md.
6. Testler: busy → tutma → yeniden deneme, IDR yok; tekrarlanan istemci KEYFRAME_REQUEST'leri + takılı yazım → en çok bir etkin IDR; T-065/066/072, T-365, T-368, T-370, T-374 testleri geçer. `./scripts/check.sh`. Çalışan uygulamaya dokunma, pencere açma, cihaz testi yok.
7. Cihaz (orkestratör): T-366 `stall-inject.sh` ile tek, sınırlı bir 200 ms video kesintisi öncesi/sonrası; `idr_cause_*`, toparlanma süresi.

## Plan

1. `VideoSendResult` (`accepted | busy | refused(write|seal|invalid|other)`) + `VideoTransport.sendResult` (varsayılan: Bool'dan `.refused(.other)`); `SocketVideoTransport` `SendOutcome`'u eşler.
2. Tutma kuyrukta: `BoundedFrameQueue.unpop` tek bir "held" kare saklar; `pop`/`first` önce onu verir, `count`/`capacity`/`queuedCount` içinde sayılır (T-370 ayrılması kendiliğinden görür, ek yuva yok), taşmada düşmez, `startNewConsumer`'da temizlenir, `breakChain` held keyframe'i korur / held delta'yı atar.
3. `VideoSender`: `.busy` -> `unpop`, `seq` ilerlemez, keyframe yok, `busyRetries++` (art arda 2. busy'den sonra 1 ms uyku, sıcak döngü yok). `.refused(kind)` -> bugünkü yol, `refusals[kind]++`, isteğe bağlı `requestKeyframeForRefusal(kind)`.
4. Koalesör: zorlanan IDR çıkış kuyruğuna ulaştıysa (`keyframesPushed` ilerledi) yazımı bitene kadar yoldadır; `request` ve `evaluateHost` zamanlayıcıyla ikinci IDR zorlamaz. Kodlayıcıda kalan IDR için eski zaman aşımı güvenlik ağı duruyor. `ForceNote.refusal` -> `idr_forced ... refusal=`.
5. Testler `BusyRetainTests.swift`; LOGGING.md.
6. (Kapsam genişletmesi, orkestratör) `VideoLink.sendResult` (SessionServer.swift), `StreamCoordinator`: `requestKeyframeForRefusal` bağı ve stats satırına `send_retry`/`refusal_*` (stats satırı StreamCoordinator.onStats'ta).
7. Ayrılma kuralı (`EncoderSubmitOrder.downstreamHasRoomLocked`): kurtarma karesi (`forceKeyframe`/`pendingBypass`) kuyruk deltalarla doluyken de tutulmaz (keyframe onları gereksiz kılar, kuyruk keyframe'den önceki deltaları atar; tutmak kilitlenme olurdu). Ama aynı anda yalnız BİR kurtarma keyframe'i hesabı atlar: önceki keyframe hâlâ kodlayıcıdaysa (`outstanding`) sonraki kurtarma karesi sıradan yakalama gibi yük kontrolünden geçer; keyframe kuyruğa inince yükte sayılır. Yardımcı (aux) yarı sayılmaz: aux-only kurtarma yeniden gönderimi tam bu durum için var. Açlık yok: önceki keyframe kendiliğinden kodlayıcıdan çıkar; takılı gönderici dayanıklılık yolunun işi.

## Handoff

Kod commit: bkz. aşağıdaki SHA (son commit). `./scripts/check.sh` ALL OK.

Dosyalar: Core/Video: `VideoSendResult.swift` (yeni), `VideoSender.swift` (+`Counters.retryLogFields`), `SocketVideoTransport.swift`, `BoundedFrameQueue.swift`, `VideoFrameQueue.swift`, `KeyframeRequestCoalescer.swift`, `EncoderSubmitOrder.swift`; Host/Video: `VideoPipeline.swift`; Host/Session: `SessionServer.swift` (`VideoLink.sendResult`), `StreamCoordinator.swift` (refusal bağı + stats `send_retry`/`refusal_*`); testler `BusyRetainTests.swift`, `EncoderBackPressureTests.swift`; `docs/LOGGING.md`.

Tasarım:
- Tutulan kare kuyruğun "held" yuvasında; `count`/`queuedCount`/kapasite içinde sayılır, T-370 `DownstreamBudget` değişmeden görür; taşma onu düşürmez.
- Koalesör: zorlanan IDR çıkış kuyruğuna ulaştıktan sonra yazımı bitene kadar zamanlayıcı ikinci IDR zorlamaz (kodlayıcıdaki IDR için eski 1 sn güvenlik ağı korundu). Takılı yazım -> T-325 watchdog / yeniden bağlanma.
- Kabul 3 kalanı: bkz. Plan madde 7 (tek kurtarma keyframe'i hesap dışı; test: `testRecoveryKeyframeEntersAQueueFullOfDeltasItSupersedes`, `testSecondRecoveryKeyframeWaitsWhileTheFirstIsStillInTheEncoder`; mevcut T-368/370/374 testleri geçer).

Cihazda doğrulanacak: kabul 7 (T-366 `stall-inject.sh`, tek 200 ms kesinti; `idr_cause_*`, `refusal_*`, `send_retry`, toparlanma süresi). Cihaz testi yapılmadı.

## Open questions

Yok. Not: bypass kuralı yalnız ana (main) kodlayıcıdaki keyframe'e bakar; aux yarısı bilerek sayılmaz (yukarıda).

## Codex --high round 1 (90a56514): üç P2 düzeltildi

1. Çekilen kare ayrılmada kalır: `BoundedFrameQueue.chargesPops` (gönderici açar). `pop` kareyi "charged" tutar; `reservedCount` (= `queuedCount`, T-370 bütçesi) onu sayar; `settlePop()` (kabul ya da kalıcı red) bırakır, `unpop` charge'ı held'e çevirir. Taşma politikası (`push`) yalnız `count` (kuyruk+held) ile yargılar, yani sağlıklı akışta ek erken düşüş yok. Testler: `testPoppedFrameStaysInTheReservationUntilSettled`.
2. Bayat `unpop` reddedilir: resync / yeni tüketici / `removeAll` charge'ı siler, `unpop` charge yoksa false döner (kare atılır). Test: `testStaleUnpopAfterAResyncIsDiscarded` (eski config geri gelmez, kurtarma IDR düşmez).
3. STARTUP yeniden denemesi: koalesör, önceki zorlanan IDR bir config'in arkasında zorlandıysa (`behindConfig`), çıkış kuyruğuna ulaştıysa ve bu resync onu atmadıysa (`ResyncResult.discardedQueuedKeyframe`, kilit altında okunur) ikinci IDR zorlamaz; config yine yeniden gönderilir (`configResent`). FRAMES_DROPPED ile zorlanmış IDR ya da resync'in attığı IDR için eski kural (yeni IDR) geçerli: T-122 gerekçesi, config'in önünde yazılan IDR yeniden kurulan çözücüye yaramaz. Bypass yeniden gönderimleri (`bypassGate`) artık yalnız kodlayıcıda başka kurtarma keyframe'i yokken oda kontrolünü atlar. Testler: `testStartupRetryDoesNotForceASecondIdrWhileTheFirstIsBeingWritten`, `testResyncReportsADiscardedQueuedKeyframe`, `testBypassResubmissionWaitsWhileARecoveryKeyframeIsInTheEncoder`.
