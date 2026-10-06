# gpt-6-astra (high) inceleme — 2026-10-07

Kullanıcı onayıyla (2026-10-06, T-283) Codex `gpt-6-astra`, `model_reasoning_effort=high`, salt okunur, `main` @ `0ff7b86b`. Kapsam ve istem T-283 kartında. Önceki değerlendirme: `docs/reviews/2026-10-04/astra-assessment.md`. "Triyaj"dan sonraki metin modelin son çıktısıdır (değiştirilmedi; dosya bağlantıları mutlak yol).

## Triyaj (orkestratör, kod okunarak doğrulandı)

| # | Bulgu | Doğrulama | Sonuç |
|---|---|---|---|
| 1 (P1) | WebDAV PUT: değiştirme başarısızsa hem eski hem yüklenen dosya silinebilir | `DavHandler.put` okundu: ilk `renameTo` başarısız, `target.delete()` başarılı, ikinci `renameTo` başarısız → `finally` geçici dosyayı siler. Yol gerçek; olasılık düşük (ext4/F2FS'te ilk rename zaten değiştirir). | **Gerçek, P2'ye indirildi** → T-288 |
| 2 (P1) | Medya hatası sağlıklı sanal ekranı yok ediyor | Bilinen. T-200 (todo) bu iş. | Yeni kart yok; T-200 açık kalıyor |
| 3 (P2) | HDR çalışma anı kodlayıcı hatası SDR'ye düşmüyor | `onPipelineFailed` aynı `live.settings` ile **bir kez** yeniden kuruyor (`pipelineRetried`); `fallBackFromHDR` yalnız başlatmada `HDRSetupError` ile. Ayrıca ikinci hata sonrası yeniden deneme yok. Cihazda görülmedi. | **Gerçek** → T-289 |
| 4 (P2) | Kodlayıcı kapanışına süre sınırı yok | Bilinen (2026-10-04 triyajı: 0025/T-199 izleniyor). Cihazda takılma görülmedi. | Kart yok, izleniyor |
| 5 (P2) | Girdi tazeliği yalnız teşhis amaçlı | Bilinen. T-199 (todo). | Yeni kart yok |
| 6 (P3) | `FrameQueue.poll()` yalnız testlerde, üretim yolunu atlıyor | `main` kaynaklarında çağıran yok (grep). | **Gerçek** → T-290 |
| — (P3) | `Planes420`/`ChromaReuseModel` üretim kaynağında ama yalnız testte kullanılıyor | Grep: yalnız `ChromaReuseTest`. | **Gerçek** → T-290 |
| — | "Sağlık = çözülen çıktı, görünen sunum değil" kısmen açık | 2026-10-04'ten bilinen; cihazda yanlış "healthy" vakası yok. | İzleniyor |

2026-10-04 bulgularının durumu: T-218, T-219 ve T-220 (iki madde), oyun geometrisi kontrolü ve 0029 düzeltmesi **kapalı**. T-200, kodlayıcı kapanış süresi, girdi tazeliği ve T-147 provası **açık**. Yeni girdi takılması, protokol uyumsuzluğu ya da özel API ihlali bulunmadı.

---

The reviewed source at **`0ff7b86b` is materially safer than `0d796e8`**, particularly around video-loss input gating and decoder-generation ownership. The remaining concerns are failure handling: file replacement can destroy existing data, media failure still destroys the virtual display, and HDR runtime failures bypass SDR fallback. I found no additional supported wire-format mismatch, stuck-input release defect, or private-API boundary violation in the inspected paths. The read-only fixture check passed; builds, native fault injection, and hardware tests were not run. No files were modified. The working-tree revision differs from the requested revision only in the review task card.

## P1

### 1. Failed file replacement can delete both the original and uploaded file

**Evidence:** [DavHandler.kt:263](/Users/burakakcan/Desktop/matebridge/client-android/app/src/main/kotlin/dev/matebridge/client/files/DavHandler.kt:263), [cleanup at :269](/Users/burakakcan/Desktop/matebridge/client-android/app/src/main/kotlin/dev/matebridge/client/files/DavHandler.kt:269).

**Scenario:** A PUT overwrites an existing file. The first `renameTo(target)` fails; the fallback successfully deletes the original, but the second rename fails—for example, following a filesystem error or permission change. The `finally` block then deletes the uploaded temporary file. The request fails with neither version preserved. This inherited WebDAV path also serves Wi-Fi transfers.

**Confidence:** High for the failure path; not reproduced on hardware.

**Fix direction:** Use atomic replacement where supported. Otherwise preserve the original through a backup/rollback sequence, and retain recoverable data if replacement fails. Never delete the destination merely because rename failed.

### 2. Media failure still destroys a healthy virtual display — T-200 remains open

**Evidence:** [VideoPipeline.swift:479](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeHost/Video/VideoPipeline.swift:479), [failure path at :492](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeHost/Video/VideoPipeline.swift:492), [StreamCoordinator.swift:667](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift:667).

**Scenario:** Capture or encoding fails while the virtual display itself remains usable. `fail()` awaits ordinary `stop()`, whose teardown invalidates the display before notifying the coordinator. Recovery therefore creates another display, forcing desktop topology and window placement changes. The existing reconnect mechanism does not establish recovery of application content affected by recreation. Normal disconnection also retains the display for only [ten seconds by default](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeCore/Video/DisplayLease.swift:18).

**Confidence:** High. This is unchanged and remains P1 for the sole-display objective.

**Fix direction:** Complete T-200’s failure classification and explicit display-ownership handoff. Retain an online display through media-only failures; invalidate it for display failure or deliberate expiry. Keep the hardware acceptance gate explicit.

## P2

### 3. HDR runtime encoder failure retries HDR instead of falling back to SDR

**Evidence:** [HEVCEncoder.swift:994](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeHost/Video/HEVCEncoder.swift:994), [failure callback at StreamCoordinator.swift:825](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift:825), [retry at :689](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift:689), [SDR fallback at :881](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift:881).

**Scenario:** Main10 setup succeeds, but encoding subsequently fails five consecutive times. The encoder reports `repeatedFailures`; the coordinator receives a stringified failure and retries `live.settings`, still HDR. The SDR fallback is reached only from the pipeline-start catch and requires `HDRSetupError`. Persistent HDR-specific runtime failure therefore keeps failing the selected mode without the fallback promised by [PROTOCOL.md:213](/Users/burakakcan/Desktop/matebridge/docs/PROTOCOL.md:213).

**Confidence:** High for control flow; occurrence depends on the native encoder.

**Fix direction:** Preserve typed failure information in coordinator events. After a bounded HDR runtime retry, announce an SDR configuration and rebuild through the existing fallback path.

### 4. Encoder teardown still has no liveness bound

**Evidence:** [HEVCEncoder.swift:826](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeHost/Video/HEVCEncoder.swift:826), [shutdown at :1017](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeHost/Video/HEVCEncoder.swift:1017), [VideoPipeline.swift:482](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeHost/Video/VideoPipeline.swift:482).

**Scenario:** `VTCompressionSessionCompleteFrames`, invalidation, or auxiliary shutdown never returns during a mode change or disconnect. The shutdown continuation never resumes, and coordinator operations awaiting teardown cannot finish. Moving the call onto its serial owner preserves ordering but does not provide recovery.

**Confidence:** High that the bound is absent; this review does not establish that a native hang currently occurs.

**Fix direction:** Detect overdue teardown and provide a controlled recovery/escalation path. Do not start another encoder alongside a stuck owner.

### 5. Input age remains diagnostic; delayed actions can execute after transport recovery

**Evidence:** [SendQueue.kt:25](/Users/burakakcan/Desktop/matebridge/client-android/app/src/main/kotlin/dev/matebridge/client/session/SendQueue.kt:25), [dequeue at :39](/Users/burakakcan/Desktop/matebridge/client-android/app/src/main/kotlin/dev/matebridge/client/session/SendQueue.kt:39), [blocking writer](/Users/burakakcan/Desktop/matebridge/client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionController.kt:975), [host injection before age recording](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeHost/Input/InputController.swift:265).

**Scenario:** A transport stall buffers a complete click or key sequence, then clears before the session closes. Queue age is checked only when another message is offered; dequeue and already-buffered TCP data have no freshness check. The host injects the delayed actions regardless of their measured age.

**Confidence:** High. Unchanged from October 4; this is action correctness, not a performance finding.

**Fix direction:** Define a coordinated stale-input policy that releases held state and requires rearming. An enqueue/dequeue limit alone cannot reject data already inside TCP; never fix this by independently dropping arbitrary up/down edges.

## P3

### 6. FrameQueue retains a separate, test-only dequeue path

**Evidence:** [FrameQueue.poll:365](/Users/burakakcan/Desktop/matebridge/client-android/app/src/main/kotlin/dev/matebridge/client/video/FrameQueue.kt:365), [production removal path at :287](/Users/burakakcan/Desktop/matebridge/client-android/app/src/main/kotlin/dev/matebridge/client/video/FrameQueue.kt:287), [FrameQueueBurstTest.kt:50](/Users/burakakcan/Desktop/matebridge/client-android/app/src/test/kotlin/dev/matebridge/client/video/FrameQueueBurstTest.kt:50).

**Scenario:** Queue tests drain through `poll()`, which directly removes an entry without the production path’s generation-ownership check and catch-up handling. Those tests can remain green while behavior in `awaitNext()`/`take()` regresses. I found no production caller of this `poll()`.

**Confidence:** High. This is a maintenance and test-fidelity issue, not an observed runtime failure.

**Fix direction:** Have tests consume through the production API with explicit ownership, then remove the alternate dequeue implementation.

## October 4 findings: closure status

| Previous finding | Status | Current evidence |
|---|---|---|
| **T-218: input remains enabled after video-only loss** | **Closed for the reported transport-loss path** | Current `VideoClosed` emits [VideoLost](/Users/burakakcan/Desktop/matebridge/client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionMachine.kt:553); [VideoHealth](/Users/burakakcan/Desktop/matebridge/client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoHealth.kt:207) faults and [input activation](/Users/burakakcan/Desktop/matebridge/client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt:753) follows health. [TCP keepalive](/Users/burakakcan/Desktop/matebridge/client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionController.kt:1231) addresses half-open connections when successfully configured. |
| **T-219: retired decoder steals replacement frames** | **Closed** | Ownership and removal are [atomic under the queue lock](/Users/burakakcan/Desktop/matebridge/client-android/app/src/main/kotlin/dev/matebridge/client/video/FrameQueue.kt:287); the renderer [assigns](/Users/burakakcan/Desktop/matebridge/client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoRenderer.kt:380) and [revokes](/Users/burakakcan/Desktop/matebridge/client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoRenderer.kt:399) consumers. |
| **T-220: inconsistent presentation criterion / missed three-vsync holds** | **Closed in code** | Common [HoldMeter rules](/Users/burakakcan/Desktop/matebridge/client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoStats.kt:448), fed by [render callbacks](/Users/burakakcan/Desktop/matebridge/client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoStats.kt:307); corrected [adaptive skip comparison](/Users/burakakcan/Desktop/matebridge/client-android/app/src/main/kotlin/dev/matebridge/client/video/AdaptivePacer.kt:263). Hardware acceptance is separate. |
| **T-220: 60 FPS content inside Game120** | **Closed in code** | [FrameInterval.resolve](/Users/burakakcan/Desktop/matebridge/client-android/app/src/main/kotlin/dev/matebridge/client/video/FrameInterval.kt:32) uses stable measured cadence to select two panel periods. |
| **T-200: display lifetime coupled to media failure** | **Open** | [Failure still calls ordinary stop](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeHost/Video/VideoPipeline.swift:499); [task remains todo](/Users/burakakcan/Desktop/matebridge/backlog/tasks/T-200-host-display-keep-on-failure.md:4). |
| **Encoder teardown liveness** | **Open** | [Shutdown waits without a deadline](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeHost/Video/HEVCEncoder.swift:1017). |
| **Input freshness** | **Open** | [Age recorded after injection](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeHost/Input/InputController.swift:265). |
| **Health means decoded output, not visible presentation** | **Partially closed overall** | Transport loss now faults, but [FirstOutput precedes buffer release—and even possible discard](/Users/burakakcan/Desktop/matebridge/client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoRenderer.kt:908). [Health still becomes HEALTHY on that event](/Users/burakakcan/Desktop/matebridge/client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoHealth.kt:187). |
| **Applied game geometry checks width only** | **Closed** | [Client checks all four dimensions](/Users/burakakcan/Desktop/matebridge/client-android/app/src/main/kotlin/dev/matebridge/client/stream/GameResolution.kt:35); [protocol corrected](/Users/burakakcan/Desktop/matebridge/docs/PROTOCOL.md:209). |
| **0029 incorrectly describes existing Game120 dimensions** | **Closed** | [Decision explicitly corrects the benefit model](/Users/burakakcan/Desktop/matebridge/docs/decisions/0029-game-display-resolution.md:12). |
| **Headless recovery rehearsal** | **Open** | [T-147’s rehearsal acceptance criteria remain unchecked](/Users/burakakcan/Desktop/matebridge/backlog/tasks/T-147-recovery-runbook.md:55). |

## Complexity I would remove

- **The alternate `FrameQueue.poll()` implementation.** Low runtime risk; moderate test migration work. Keep one authoritative removal path.
- **Test-only CPU chroma models in production sources.** Move [Planes420 / ChromaReuseModel](/Users/burakakcan/Desktop/matebridge/client-android/app/src/main/kotlin/dev/matebridge/client/video/ChromaReuse.kt:32) into test support while retaining runtime constants and policies. Low risk.
- **Split setup/runtime fallback handling.** Centralize typed media-failure policy so HDR recovery cannot bypass it. Medium risk because configuration announcements, display ownership, and retry limits must remain ordered.