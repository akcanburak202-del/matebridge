---
id: T-378
title: Host — video yazımı geçici `.busy` reddinde kareyi tut ve yeniden dene; tek toparlanma kuşağı (astra öneri 2)
status: todo
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

## Open questions
