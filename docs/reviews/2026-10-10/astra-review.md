# gpt-6-astra (xhigh) inceleme — 2026-10-10

Kullanıcı onayıyla (2026-10-10 ~00:45, T-329) Codex `gpt-6-astra`, `model_reasoning_effort=xhigh`, salt okunur, `main` @ `7bf1765e`. Kapsam ve istem T-329 kartında. Önceki inceleme: `docs/reviews/2026-10-07/astra-review.md` (`0ff7b86b`). "Triyaj"dan sonraki metin modelin son çıktısı; değiştirilmedi.

## Triyaj (orkestratör, kod okunarak doğrulandı)

| # | Bulgu | Doğrulama | Sonuç |
|---|---|---|---|
| 1 (P1) | WebDAV: başarısız ya da iptal edilen COPY, aynı hedefe başka bağlantıdan yapılmış başarılı PUT'u silip eski yedeği geri koyar | `DavServer` her bağlantıya ayrı iş parçacığı açıyor. `moveOrCopy` `finally` bloğunda `d`'de ne varsa siliyor, sonra `aside`'ı geri koyuyor; yol kilidi ya da sahiplik kontrolü yok. Aynı yola eşzamanlı COPY + PUT gerekiyor (Finder için olası değil). | **Gerçek, P2'ye indirildi** → T-334 |
| 2 (P1) | Medya hatası sağlıklı sanal ekranı yok ediyor | Bilinen, değişmedi. | T-200 açık kalıyor |
| 3 (P2) | Teardown sürerken ikinci bir stop çağıranı (`restartPipeline`) eski ekran yaşarken yenisini kuruyor | `fail()` → `stop()` durumu hemen `stopped` yapıyor, teardown 3+3 sn'ye kadar sürebiliyor. Bu arada `stopKeepingDisplay()` `nil` dönüyor ve `createPipeline(reusing: nil)` aynı kimlikle ikinci bir ekran açmayı deniyor. Pencere dar: hata anında ayar değişikliği gerekiyor. | **Gerçek, P2** → T-335 |
| 4 (P2) | Hata zamanı teardown'dan sonra alındığı için devre kesici ve HDR hata geçmişi yanlışlıkla sıfırlanabiliyor | `onPipelineFailed` içinde `failedAt` teardown'dan sonra alınıyor; `settleIfStable`, `successUs` (10 sn) geçmişse geçmişi siliyor. Yavaş teardown (≤6 sn) + 4–10 sn'de bir düşen pipeline gerekiyor. | **Gerçek, P3'e indirildi** → T-335 |
| 5 (P2) | Geciken girdi taşıma düzelince yine de uygulanıyor | Bilinen, ölçüm kapısı arkasında. | T-199 açık kalıyor |

Önceki bulgular:
- **Kapandı:** T-288 (tekil istekte), T-290, sınırsız teardown bekleme (T-325).
- **Kapandı, koşullu:** T-289 (#4 ile).
- **Açık:** T-200, T-199, "çözülen ≠ görünen sağlık", T-147 provası.

Yeni girdi takılması, protokol uyumsuzluğu, AEAD nonce/replay hatası ya da `VirtualDisplay` ihlali bulunmadı.

---

Compared with `0ff7b86b`, the code at **`7bf1765e` materially improves recovery**: teardown waits are bounded, watchdog restart requires confirmed input release, and HDR failures now have a typed SDR fallback path. The original single-request PUT data-loss bug is fixed. However, concurrent WebDAV rollback can still destroy a successful upload, and pipeline teardown has ownership and timing gaps that undermine recovery. T-200’s display-lifetime problem and T-199’s stale-input problem remain. I found no additional supported wire-format mismatch, AEAD nonce/replay defect, or `VirtualDisplay` private-API boundary violation in the inspected paths.

**P1**

**1. A failed COPY can delete another connection’s successful upload**

Evidence: concurrent connection workers in [client-android/app/src/main/kotlin/dev/matebridge/client/files/DavServer.kt:129](/Users/burakakcan/Desktop/matebridge/client-android/app/src/main/kotlin/dev/matebridge/client/files/DavServer.kt:129); destination rollback in [client-android/app/src/main/kotlin/dev/matebridge/client/files/DavHandler.kt:376](/Users/burakakcan/Desktop/matebridge/client-android/app/src/main/kotlin/dev/matebridge/client/files/DavHandler.kt:376); PUT commit at [DavHandler.kt:266](/Users/burakakcan/Desktop/matebridge/client-android/app/src/main/kotlin/dev/matebridge/client/files/DavHandler.kt:266).

Scenario: COPY moves destination `D` aside and starts copying directly into `D`. Meanwhile, another connection successfully PUTs a new file at `D` and receives 204. The COPY then fails or is cancelled when the server stops. Its `finally` deletes whatever currently occupies `D`—including the completed upload—and restores the older backup. No overlapping-path synchronization or ownership check protects rollback.

**Confidence:** High from control flow; not reproduced. This is an inherited concurrency defect adjacent to T-288.

**Fix direction:** Serialize mutations of overlapping paths, including ancestor/descendant operations. Stage COPY privately and ensure rollback only removes objects owned by that operation. Add a barrier-controlled COPY/PUT/cancellation test.

**2. Media failure still destroys a healthy virtual display — T-200**

Evidence: failure invokes ordinary stop in [host-mac/Sources/MateBridgeHost/Video/VideoPipeline.swift:514](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeHost/Video/VideoPipeline.swift:514); teardown invalidates the display at [VideoPipeline.swift:508](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeHost/Video/VideoPipeline.swift:508); recovery assumes its loss in [host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift:821](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift:821).

Scenario: ScreenCaptureKit or the encoder fails while the display remains online. Recovery removes that display and later creates another, changing desktop topology and moving application windows/panels. The new retry machinery can repeat this disruption. This remains P1 for the tablet-as-sole-display objective.

**Confidence:** High; unchanged from the previous review.

**Fix direction:** Complete T-200’s failure classification and explicit display handoff. Preserve an online display through media-only failure, subject to the card’s hardware acceptance criteria.

**P2**

**3. A second stop caller can rebuild before the first teardown finishes**

Evidence: [host-mac/Sources/MateBridgeHost/Video/VideoPipeline.swift:456](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeHost/Video/VideoPipeline.swift:456), [stopKeepingDisplay at :463](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeHost/Video/VideoPipeline.swift:463), and [host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift:925](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift:925).

Scenario: an encoder failure starts asynchronous `stop()`, marks the pipeline stopped, and waits for capture/encoder teardown while retaining the old display. Before the failure callback reaches the coordinator, a preferences change invokes `restartPipeline()`. `stopKeepingDisplay()` immediately returns `nil` because the state is already stopped; the coordinator starts constructing a replacement while the old display still exists. The code itself documents that simultaneous displays with the same identity cannot be created.

T-325 bounds the first teardown’s waits but does not make subsequent stop callers join it.

**Confidence:** High for the race; native creation failure not reproduced.

**Fix direction:** Represent teardown-in-progress separately from teardown-complete. All stop callers should join one teardown operation and receive a definitive display-ownership result before replacement begins.

**4. Teardown time can incorrectly reset the circuit breaker and HDR failure history**

Evidence: failure notification follows teardown in [host-mac/Sources/MateBridgeHost/Video/VideoPipeline.swift:520](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeHost/Video/VideoPipeline.swift:520); failure time is sampled afterward in [host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift:817](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift:817); ten-second “success” clears history in [host-mac/Sources/MateBridgeCore/Video/PipelineRetryPolicy.swift:174](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeCore/Video/PipelineRetryPolicy.swift:174).

Scenario: a pipeline fails eight seconds after startup, then capture and encoder cleanup take three seconds combined. The policy receives a failure timestamp eleven seconds after startup and classifies that failed run as stable. Repeating this pattern clears previous failures before testing the HDR fallback or retry budget, allowing repeated same-mode rebuilds without reaching the intended breaker/fallback.

**Confidence:** High. This affects the new T-293/T-325 recovery integration.

**Fix direction:** Capture the first failure timestamp before teardown and carry it through the coordinator event. Base stability on runtime up to failure. Test short failed runs with delayed cleanup.

**5. Delayed input is still executed after transport recovery — T-199**

Evidence: age checked only on enqueue in [client-android/app/src/main/kotlin/dev/matebridge/client/session/SendQueue.kt:29](/Users/burakakcan/Desktop/matebridge/client-android/app/src/main/kotlin/dev/matebridge/client/session/SendQueue.kt:29); dequeue has no age check at [SendQueue.kt:46](/Users/burakakcan/Desktop/matebridge/client-android/app/src/main/kotlin/dev/matebridge/client/session/SendQueue.kt:46); host injects before recording age in [host-mac/Sources/MateBridgeHost/Input/InputController.swift:302](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeHost/Input/InputController.swift:302).

Scenario: congestion buffers a complete click, key sequence, or stroke and clears before the connection is closed. Those actions execute late, potentially against a changed application state. T-322’s send-age instrumentation measures this; it does not prevent it.

**Confidence:** High; inherited and explicitly tracked.

**Fix direction:** Implement the coordinated stale-input policy after T-199’s measurement gate. Preserve releases of already-applied presses and suppress stale openings with their associated state; do not independently discard arbitrary edges.

**P3**

No additional supported findings.

**Previous-review status**

- **T-288: closed for the reported single-request replacement failure.** Atomic replace plus backup/rollback preserves recoverable content. Finding 1 is a separate concurrency gap.
- **T-289: core fix implemented, closure qualified by finding 4.** Repeated runtime HDR encoder failures can now announce SDR with a new configuration.
- **Unbounded encoder teardown: original coordinator-wait defect closed by T-325.** Abandoned operations are tracked and escalation requires confirmed input release; finding 3 remains.
- **T-290: closed.** The alternate production `FrameQueue.poll()` path and test-only chroma models were removed/moved.
- **Still open:** T-200, T-199, decode-output versus visible-presentation health, and T-147’s hardware recovery rehearsal.

**Verification limits**

- Read-only fixture generator check and `git diff --check` passed. No files were modified.
- Builds, `./scripts/check.sh`, Swift/Kotlin fixture suites, and native fault injection were not run.
- Hardware verification remains necessary for held-input release across watchdog restart/sleep/detach; teardown races; HDR fallback; AAudio resume; decoder parking; and Wi-Fi adaptation/DSCP. Both network knobs remain default-off.
- During review, HEAD advanced to `05625835`; its changes beyond `7bf1765e` were documentation/task cards only, leaving the reviewed code unchanged.