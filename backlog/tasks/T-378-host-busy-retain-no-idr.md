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

## Handoff

Kod commit: 332cf60a (bu kart güncellemesi ayrı commit). `./scripts/check.sh`: ALL OK (731 XCTest + 1323 Swift Testing).

Dosyalar: Core/Video: `VideoSendResult.swift` (yeni), `VideoSender.swift`, `SocketVideoTransport.swift`, `BoundedFrameQueue.swift`, `VideoFrameQueue.swift`, `KeyframeRequestCoalescer.swift`; Host/Video: `VideoPipeline.swift` (`requestKeyframe(refusal:)`); test `BusyRetainTests.swift`; `docs/LOGGING.md`.

Varsayımlar / tasarım:
- Tutulan kare kuyruğun "held" yuvasında; `count`/`queuedCount`/kapasite içinde sayılır, bu yüzden T-370 `DownstreamBudget` değişmeden onu görür. Taşma held kareyi düşürmez.
- Kabul 3 kapsamı: istemci KEYFRAME_REQUEST ve host-drop yolları, zorlanan IDR çıkış kuyruğuna ulaştıktan sonra yazımı bitene kadar zamanlayıcıyla ikinci IDR üretmez (`reachedQueue`). Kodlayıcıda kalmış IDR için eski 1 sn güvenlik ağı korundu (T-122/T-176 testleri bunu kilitliyor; kodlayıcı zaten force bayrağını tutar). `EncoderSubmitOrder` bypass (`forceKeyframe`/`pendingBypass`) kapısına DOKUNULMADI: koalesleme ikinci kaçışı engelliyor, ama bypass karelerinin ayrılmaya katılması yapılmadı.
- Takılı IDR yazımı artık yalnız mevcut dayanıklılık yoluna (T-325 watchdog / yeniden bağlanma) kalır.

Gerçek cihazda doğrulanacak: kabul 7 (T-366 `stall-inject.sh` ile tek 200 ms kesinti, `idr_cause_*`, toparlanma süresi). Hiç cihaz testi yapılmadı.

## Open questions

KAPSAM DIŞI, üretimde şu iki bağ olmadan özellik etkisiz (varsayılan `sendResult` Bool'a düşer, davranış eskisi gibi):
1. `host-mac/Sources/MateBridgeHost/Session/SessionServer.swift`: `VideoLink` `transport` özel olduğundan `sendResult`'ı başka dosyadan yazamam. Eklenecek: `VideoLink.send` gövdesinin `switch transport.sendFrame(...)` kısmını `sendResult(_:completion:) -> VideoSendResult` yapan (log satırları aynı; `.busy`->`.busy`, `.writeRefused`->`.refused(.write)`, `.invalid`->`.refused(.invalid)`, `.sealFailed`->`.refused(.seal)`) ve `extension VideoLink: VideoTransport` içinde bunu sunan ~15 satır; `send` onu `isAccepted` ile çağırır.
2. `StreamCoordinator.swift` (~satır 705): `VideoSender(...)`'a `requestKeyframeForRefusal: { [weak pipeline] in pipeline?.requestKeyframe(refusal: $0) }` ve stats satırına `now.busyRetries - last.busyRetries` -> `send_retry=<n>`.
Karar bekleyen: bypass IDR karelerini T-370 ayrılmasına katmak (kabul 3 son cümle) ayrı kart olabilir.
