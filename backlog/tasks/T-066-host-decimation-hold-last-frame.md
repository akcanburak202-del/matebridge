---
id: T-066
title: Mac — seyreltmede ızgaradan erken gelen kare atılmaz, tutulur (son değişiklik her zaman gönderilir)
status: review
phase: 5
owner: mac-host-dev
depends_on: [T-058]
decisions: []
files:
  - host-mac/Sources/MateBridgeCore/Video/FrameGate.swift
  - host-mac/Sources/MateBridgeCore/Video/CadenceMeter.swift   # needed for the `deferred` counter
  - host-mac/Sources/MateBridgeHost/Video/HEVCEncoder.swift
  - host-mac/Tests/
  - backlog/tasks/T-066-host-decimation-hold-last-frame.md
---

## Amaç

T-062 teşhisi. `FramePacer.offer` seyreltmede (`decimating`, panel 60 Hz iken 120 fps akış) ızgaradan önce gelen kareyi **atıyor** (`decimatedCount`, `.drop`). İçerik bir kez değişip duruyorsa (yazma: bir tuş genellikle 8,3 ms arayla iki kare üretir — karakter, sonra imleç/yeniden çizim) son kare hiç kodlanmıyor; tablet ara durumu gösterip bir sonraki değişikliğe kadar bekliyor. Şu an çalışan host (`bdf52f0`) seyreltme öncesi olduğu için kullanıcı bunu henüz görmedi; `main`'de var.

Değişmez: **yakalanan en yeni kare, sınırlı süre içinde kodlayıcıya verilir**; yalnızca daha yeni bir kare onun yerini alırsa atlanır.

## Kabul kriterleri

- [ ] Seyreltmede ızgaradan erken gelen kare `pending` olarak tutulur (en yeni kazanır). Izgara karesi gelirse onu değiştirir (bugünkü eşit aralıklı seçim korunur). Gelmezse bekleyen kare kendi slotunda + küçük bir pay (ör. kaynak aralığının yarısı; gerekçelendir) dolunca zamanlayıcıyla gönderilir. Sürekli 120→60 akışta gönderilen kareler hâlâ eşit aralıklı (zamanlayıcı yalnızca ardıl gelmediğinde devreye girer).
- [ ] Zamanlayıcıyla gönderilen kare, ızgarayı (gate) normal kabul gibi ilerletir; zaman damgaları geri gitmez (`lastSubmittedPtsUs`).
- [ ] `ev=cadence` satırında `decimated` artık yalnızca gerçekten atılan (değiştirilen) kareleri sayar; zamanlayıcıyla gönderilen ayrı sayılabilir (ör. `deferred=`), alan eklersen `docs/LOGGING.md`'yi değiştirme, karta yaz.
- [ ] Testler (`FrameGate`/`FramePacer` saf mantık): (1) 120 fps akış 60'a seyreltme: gönderilen aralıklar eşit, zamanlayıcı hiç tetiklenmez; (2) tek değişiklik: ızgaradan erken tek kare → slot + pay içinde gönderilir; (3) iki kare 8,3 ms arayla, sonra durgunluk → **ikinci kare gönderilir**; (4) 60→120 yükselişi hemen; (5) seyreltme kapalıyken davranış değişmez.
- [ ] `./scripts/check.sh` geçiyor.

## Kapsam dışı

- Tablet tarafı (T-065), SCK/kodlayıcı ayarları.

## Plan

1. `FramePacer` decimation: an off-grid capture is held as the single pending (newest wins) with `readyAt = nextSlot + deliveryLag + grace` (lag = arrival - capture of that frame, so the capture-timestamp grid is compared in the arrival domain; review fix), grace = half a source interval (4.17 ms at 120 fps: grid frames arrive within ~2 ms jitter, so a grid frame beats the timer on a live stream; added latency < one source interval). A grid frame replaces it (counted `decimated`).
2. `takePending` (slot release or timer) in decimation mode honours `readyAt`, so a stale timer cannot flush a newer pending early; a deferred frame sent this way advances the gate (`accept(pts)`) and counts `deferred`; `lastSubmittedPtsUs` stays monotonic.
3. `HEVCEncoder` already arms the flush from `.hold(retryAfterUs:)`; only reports `deferred` to the meter. `CadenceMeter` gets `deferred=`.
4. Tests in `DecimationTests`.

## Handoff

- **Commit:** tip of `task/T-066-host-decimation-hold` (SHA in the agent's report).
- **Dokunulan dosyalar:** `MateBridgeCore/Video/FrameGate.swift`, `MateBridgeCore/Video/CadenceMeter.swift` (not in `files:` literally but in the Video area of the same feature: `deferred` counter), `MateBridgeHost/Video/HEVCEncoder.swift`, `Tests/.../FrameGateTests.swift`, `CadenceTests.swift`.
- **Review fix:** readyAt includes the frame's own delivery lag; tests with 6 ms lag and +-1.5 ms jitter (deferred stays 0, even gaps; lone frame still sent).
- **Varsayimlar:** grace = source interval / 2 (see Plan). Timer interaction: the existing encoder flush timer is armed from `.hold(retryAfterUs)` (= readyAt - now); on fire `takePending` returns `.retry` if not yet due (stale timer), `.submit` if due. If a pending frame had already passed the grid (slot busy) a newer off-grid frame replaces it but keeps it ready (goes out on slot release, gate already advanced). `ev=cadence`: `decimated` = superseded frames only; new `deferred=` = timer-sent frames (LOGGING.md untouched). Keyframe bypass unchanged; non-decimating path unchanged.
- **Test edilmeyenler / cihazda dogrulanacaklar:** nothing on real capture. On device at hz=60/120 fps: steady scroll should show `deferred~0` and even gaps; a single typed char / lone change must appear on the tablet (`deferred>0` in sparse updates); then the first-key-after-idle check.
- **Acik sorular:** none.
