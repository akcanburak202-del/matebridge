# Astra (gpt-6-astra, high) — Wi-Fi'da oyun: takılma ve toparlanma tasarım incelemesi

- Tarih: 2026-10-25, main `2fc62354` sonrası. Kart: T-377. Salt okunur, kod değişikliği yok.
- İstem: scratch `astra-wifi-prompt.txt` (WIFI_ADAPT çöküşü, yeniden tasarım, T-372/T-373, diğer kaldıraçlar).

## Orkestratör triyajı

Kontrol edilen iddialar (kod okunarak): `VideoSender.run` yazım reddinde (`accepted == false`) türüne bakmadan keyframe istiyor (`VideoSender.swift` ~210), `SocketVideoTransport` ise `.busy`'yi ayrı ayırt ediyor (`:26`, `:90`) → öneri 2'nin temeli doğru. `MATEBRIDGE_RATE_WINDOW_MS` düğmesi var (`EncoderKnobs.swift:33`, 10…999 ms) → öneri 3 kod gerektirmez.

| # | Öneri | Karar | Kart |
|---|---|---|---|
| 2 | Geçici `.busy` reddinde kareyi tut ve yeniden dene (IDR isteme), tek etkin toparlanma kuşağı, toparlanma karelerinin hesaba katılması | **Önce bu.** Öneri 1'in ön koşulu; tek başına da 23 Ekim'deki 5 `transport_refused` IDR'ını hedefler. Protokol değişmez. | T-378 (host) |
| 1 | WIFI_ADAPT yerine yalnız bit hızı değiştiren, kanıtı doğrulanmış tıkanıklık yanıtı (ek kabul kapısı yok; taban 30, acil 20; 3 sn temizse +2 Mbps/sn) | **Kabul, T-378'den sonra.** 0023 eki gerekir (kontrol yasası, sabitler). Varsayılan kapalı başlar, cihaz A/B'si ile açılır. | T-379 (host, karar eki ile) |
| 3 | `MATEBRIDGE_RATE_WINDOW_MS` 50 / 33 ms A/B (büyük IDR patlamalarını kısaltır) | **Kabul, kod yok.** Bir sonraki oyun oturumunda cihaz denemesi; NOTES ertelenen testler listesine. | — |
| 4 | DSCP doğrulaması (tcpdump) + `ef` A/B | Zaten ertelenen listede (NOTES 2026-10-09 akşam). | — |
| 5 | Video için soket hızlandırıcı (token bucket) | Koşullu; 1–3 sonrası patlama kanıtı kalırsa. | — |
| 6 | LTR (T-373) | Ertelendi: HEVC/HiSilicon doğrulaması + protokol değişikliği, L. | T-373 kalır |
| — | T-372 (IDR arkasında delta tutma, 150 ms kuyruk) | Astra: T-370 sonrası gerek kalmadı, kapatılmaya aday. Öneri 2'den sonra iz kalırsa yeniden açılır. | T-372 → kullanıcıya |
| — | Ölçüm: ">150 ms takılma" 1 sn ortalaması, bazı donmaları kaçırıyor; gösterim boşlukları (`render_cb`/PaceTrace) rapora eklensin | Kabul; T-379 ölçüm adımına ve `game_ab.py`'ye küçük ek. | T-379 içinde |

Ayrıca kayda değer: uzun TotK oturumunda düşük fps'li saniyelerin 1302/1704'ünde **Mac'in yakaladığı kare** zaten düşüktü (oyunun kendi fps'i), yani bu saniyeleri ağ düzeltmesi kurtarmaz.

## Astra çıktısı (aynen)

**Executive summary**

- **Keep 60 Mbps as the ceiling, but replace WIFI_ADAPT’s coupled bitrate/admission controller.** Bad-day evidence supports reducing offered load; good-day evidence does not support permanently lowering the default.
- **The collapse was positive feedback:** RTT-triggered reductions → smaller socket budget → encoded-frame overflow → forced IDRs → further RTT inflation. T-370 removes the ordinary overflow path, but recovery bypasses still need bounded accounting.
- **Prioritize protocol-neutral work:** bitrate-only adaptation, lossless handling of temporary transport refusal, and testing the existing short `DataRateLimits` window.
- **Do not add a larger client jitter buffer or a 150 ms host FIFO by default.** Client decode-through catch-up already exists. T-372 is conditional; T-373 LTR needs codec validation and a real protocol extension.
- **The reported 0.31→0.03 stalls/min improvement is encouraging but measures one-second capture-to-decode averages—not individual visible freezes.** Validate presentation gaps and distinguish TotK source-frame drops from streaming faults.

Read-only review completed. No files, settings, applications, or devices were changed; builds and disruptive tests were not run. Cached `wifi-runs` files existed, but contained no `adapt` events, so the failed controller run’s device evidence below comes from NOTES, cross-checked against code.

**Why WIFI_ADAPT collapsed**

1. **Its primary trigger does not establish congestion.** The controller compares video SRTT with the minimum SRTT in a rolling 30-second window. An excess of 20 ms alone selects a ×0.7 reduction; it requires neither persistent backlog nor retransmission. The driver samples every 100 ms. See [CongestionController.swift:204](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeCore/Session/CongestionController.swift:204) and [WifiAdaptationDriver.swift:19](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeHost/Video/WifiAdaptationDriver.swift:19).

   A burst, ACK timing, or wireless contention can therefore be interpreted as sustained overload. **Inference:** SRTT was useful evidence of trouble but insufficient evidence that another bitrate reduction would help.

   One precision issue in NOTES: **10–13 ms SRTT cannot itself satisfy a minimum-plus-20-ms trigger.** Those values describe the preceding clean network; the triggering subsecond samples are not provided. The code establishes the mechanism, but the available summary cannot reconstruct the exact first triggering sample.

2. **The decrease gain compounds much faster than the system settles.** Reductions are allowed every `max(srtt,250 ms)`—typically every 300 ms with a 100 ms timer. Five ×0.7 steps take 60 Mbps to the 12 Mbps floor in roughly 1.2 seconds after the first step. Every trigger resets the quiet timer, including triggers at the floor. Recovery requires two quiet seconds, then +3 Mbps/s at a 60 Mbps ceiling, or an idle jump. See [CongestionController.swift:284](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeCore/Session/CongestionController.swift:284).

   Also, the “fewer than four retransmissions” threshold was described/calibrated for approximately one-second windows but is applied to 100 ms deltas. Its meaning changes with sampling frequency.

3. **Reducing bitrate also tightens a second actuator—the send gate.** Its budget is:

   `max(target bitrate × 20 ms, EWMA frame size)`

   The bitrate-derived component is 150 KB at 60 Mbps, 75 KB at 30 Mbps, and 30 KB at 12 Mbps. These are **not necessarily the actual budgets**, because the frame-size EWMA can dominate. Admission checks existing socket bytes before sending a whole frame; it does not cap that frame’s size. See [CongestionController.swift:163](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeCore/Session/CongestionController.swift:163).

   Thus a large IDR can enter, overshoot the budget, and close admission behind it. The floor’s rationale also conflates encoder target with available link throughput: setting 12 Mbps does not guarantee that an existing IDR drains at 12 Mbps.

4. **Before T-370, closed admission destroyed encoded reference chains.** The two-frame queue continued receiving encoded frames. For `[IDR,d1] + d2`, it discarded `d1`, purged dependent `d2`, and required another IDR. Keeping the earlier IDR does not repair references encoded after the missing delta. See [BoundedFrameQueue.swift:9](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeCore/Video/BoundedFrameQueue.swift:9).

   WIFI_ADAPT suppresses some queue-drop feedback when its gate caused the drop, but **does not suppress the independently operating IDR machinery or RTT trigger**. Its 400 ms send-buffer rule protects only that particular trigger. See [WifiAdaptation.swift:197](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeCore/Session/WifiAdaptation.swift:197).

   The recorded result was approximately 400 ms blocked/s, 12 queue drops/s, four IDRs/s, SRTT rising to 40–70 ms, and 13–20 client fps. That closes the feedback loop. [NOTES, 2026-10-23 adaptation failure](/Users/burakakcan/Desktop/matebridge/docs/NOTES.md:2052).

5. **FrameGate added a separate latency penalty.** Forced resubmissions formerly advanced the capture pacing grid, leaving normal frames waiting another 8–9 ms for tens of seconds. T-368 exempts bypass frames from advancing that grid. This amplified latency but was not the original congestion signal. [FrameGate.swift:251](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeCore/Video/FrameGate.swift:251).

   T-370 now accounts for encoded-queue occupancy plus encoder work and replaces captures **before encoding**. The later run recorded zero queue drops, versus 863 previously, despite retransmission-active seconds increasing from 33% to 41%. However, forced keyframes and pending bypass frames remain exempt from ordinary downstream admission. Therefore, neither “the old collapse still necessarily occurs” nor “T-370 makes the old controller safe” is established. [EncoderSubmitOrder.swift:508](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeCore/Video/EncoderSubmitOrder.swift:508), [NOTES, post-T-370](/Users/burakakcan/Desktop/matebridge/docs/NOTES.md:2069).

**Ranked proposals**

Ranking reflects expected improvement per implementation effort. The recovery invariants in proposal 2 are a prerequisite for enabling proposal 1.

| Rank | Proposal | Expected benefit | Effort | Wire change |
|---|---|---|---|---|
| 1 | Bitrate-only, corroborated congestion response | Largest prospective benefit on bad WLAN days | M | No |
| 2 | Preserve frames on temporary refusal; bound recovery generations | Removes remaining self-induced recovery amplification | M | No |
| 3 | Test short encoder rate windows | Cheap reduction of large burst cost | S | No |
| 4 | Verify explicit DSCP and A/B it | Possible contention/audio improvement | S | No |
| 5 | Conditional socket pacing experiment | Possible residual burst reduction; latency tradeoff | M | No |
| 6 | LTR feasibility, then negotiated recovery | Potentially smaller recovery frames | L overall | Yes |

**1. Replace WIFI_ADAPT with bitrate-only congestion response**

**Problem/evidence.** On 2026-10-08, 60 Mbps produced high tablet ping and stalls; 30 Mbps restored low latency. On 2026-10-20, 54/55 large latency samples followed video retransmission or RTT above 50 ms. Conversely, the good-day A/B did not justify changing the default. [NOTES:1872](/Users/burakakcan/Desktop/matebridge/docs/NOTES.md:1872), [NOTES:1999](/Users/burakakcan/Desktop/matebridge/docs/NOTES.md:1999), [game-mode A/B:109](/Users/burakakcan/Desktop/matebridge/docs/research/2026-10-23-game-modes.md:109).

**Proposed change.** Initially remove the additional WIFI_ADAPT admission gate. Retain existing socket backpressure and T-370; change only live encoder bitrate, without restarting the stream, changing display mode, or forcing an IDR.

Use these signals:

| Signal | Proposed role |
|---|---|
| Video TCP SRTT excess | Delay evidence, requiring corroboration and persistence |
| Retransmitted/total packets over a rolling **one second** | Loss severity; not a raw per-tick packet threshold |
| `sndbuf_bytes`, `user_pending_bytes`, oldest queued/write age | Evidence that outstanding work persists rather than promptly drains |
| `snd_cwnd`, `snd_wnd`, `loss_recovery` | Diagnose TCP recovery versus receiver limitation |
| Existing STATS | Slow end-to-end confirmation and recovery monitoring |
| Host `gate_wait`, encoder time, `cap_fps` | Exclude host/source problems from network diagnosis |

**Do not treat `unacked_bytes` as an exact flight-size measurement.** It is `min(sbbytes,cwnd,snd_wnd)`; `notsent_bytes` is derived from that estimate. Use raw `sndbuf_bytes` and its evolution instead. [TcpInfoLog.swift:60](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeCore/Session/TcpInfoLog.swift:60).

**STATS contains no arrival-jitter or transport-OWD fields.** `latency_avg_us` includes capture, host processing, transport, and decoder delay. Subtracting decoder average does not isolate network delay. Client interarrival percentiles are local logs and also reflect source cadence. No protocol extension is necessary for the first controller. [PROTOCOL.md:635](/Users/burakakcan/Desktop/matebridge/docs/PROTOCOL.md:635).

A concrete initial control law—**proposed calibration, not device-proven constants**:

- Sample TCP every **100 ms**; aggregate decisions over **500 ms** and loss over **one second**. Reset baselines on connection changes. Update a low-percentile RTT baseline from active, draining periods; do not learn persistent congestion as the new baseline.
- **Moderate congestion:** SRTT excess ≥20 ms in at least three of five samples **and** backlog fails to drain for ≥250 ms. Alternatively, retransmissions ≥1% with at least four retransmitted packets in one second, again with persistent backlog.
- **Severe congestion:** SRTT excess ≥50 ms with sustained write/queue blocking, or outstanding video makes no progress for ≥500 ms.
- Moderate response: **×0.85**, at most once per **750 ms**. Severe response: **×0.7**, at most once per **500 ms**. Require fresh evidence after each step; do not repeatedly react to one stale SRTT excursion.
- Isolated retransmissions with normal RTT and draining queues: **hold upward probing for two seconds**, without automatically reducing bitrate.
- Start with **30 Mbps as the normal lower operating point**, since that has bad-day evidence. Permit an experimental **20 Mbps emergency floor** only after another two seconds of corroborated overload. Clamp both to a lower user ceiling. The 20 Mbps value needs quality validation; the failed 12 Mbps controller run does not establish that 12 Mbps itself is intrinsically unusable.
- After **three clean seconds**, increase **2 Mbps once per second**, up to the configured ceiling. No immediate idle jump: low demand demonstrates little about available capacity when motion resumes.
- At the floor, retain bounded pre-encode replacement. Do not tighten admission, generate IDRs, or rebuild the virtual display merely because congestion persists.

Tag large keyframe/scene-change bursts. Give a **draining** burst one settling interval before treating it as sustained backlog; do not grant an exemption while bytes remain stuck.

**Expected gain—inference.** Maintain 60 Mbps on healthy days and approach the previously successful ~30 Mbps region during sustained overload, without converting congestion into reference-chain damage. It cannot prevent a freeze while TCP is waiting for missing bytes.

**Risks.** Misclassification, visible quality changes, oscillation, or an emergency floor still above usable capacity. Restrict the controller to local game-mode video; never gate input/control or change release-all behavior. Add local diagnostic fields for baseline, sustained evidence, queued age, and effective bitrate; these require no wire change.

**Measurement.** Compare current fixed-60/T-370 against the new controller on healthy and degraded WLAN. Require no congestion-induced `queue_overflow` IDRs, no persistent floor lock, stable healthy-path `gate_wait`/presentation latency, and recovery toward ceiling after the link improves. Confirm actual `sent_kbps` follows `bitrate_set`; successful property setting alone is insufficient.

**2. Make temporary backpressure lossless and recovery explicitly bounded; defer larger T-372 buffering**

**Problem/evidence.** Post-T-370, five forced-IDR causes were `transport_refused`, while queue-overflow causes were zero. The transport distinguishes `.busy` from invalid/write/sealing failures, but `VideoTransport.send` collapses these to `Bool`; the sender requests a keyframe on refusal. [SocketVideoTransport.swift:22](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeCore/Video/SocketVideoTransport.swift:22), [VideoSender.swift:201](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeCore/Video/VideoSender.swift:201).

**Inference:** a temporary admission race is worth investigating, but the existing cause log does not prove those five refusals were `.busy`.

**Proposed change.**

- Preserve typed send outcomes. On `.busy`, retain the exact encoded frame and retry it; do not consume its sequence/counter or request an IDR.
- Count that retained frame in downstream reservations. An extra unaccounted retry slot would recreate the overflow problem.
- Maintain **one active recovery generation per stream** across encoding, queued output, and socket writing. Repeated requests for the same recovery coalesce.
- Reserve capacity for recovery config/IDR instead of letting `forceKeyframe`/`pendingBypass` escape accounting repeatedly.
- While blocked, replace only the newest **unencoded** capture. Never discard a reference delta and continue sending its dependent deltas.
- A watchdog should detect failed recovery and use the existing bounded failure/reconnection path; it must not enqueue another IDR solely because a timer expired while the first remains in flight.
- Never discard or reorder part of a sealed TCP record. A connection failure requires a fresh video handshake and keys.

These establish the relevant “never loop” property: **congestion admission cannot itself create encoded loss, and blocked recovery cannot multiply recovery frames.** They cannot guarantee delivery during a WLAN outage.

**T-372 assessment.** The proposed 150 ms host queue is no longer the obvious next step: ordinary production already stops before overflow. Prefer preserving the existing bounded chain behind an IDR while stopping upstream encoding. Only enlarge preservation limits if post-fix traces demonstrate a specific remaining overflow. That would require a newest-wins exception/decision and updating the documented two-frame queue contract, even if wire bytes remain unchanged.

The client already decodes bounded catch-up frames in order and skips stale **presentation**, with time/count/byte bounds. It does not need a new general catch-up mechanism. [PROTOCOL.md:830](/Users/burakakcan/Desktop/matebridge/docs/PROTOCOL.md:830), [VideoRenderer.kt:853](/Users/burakakcan/Desktop/matebridge/client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoRenderer.kt:853).

**Expected gain—inference.** Eliminate avoidable recovery IDRs and protect adaptation from positive feedback, without introducing steady-state buffering.

**Risks.** Reservation deadlock, stale recovery generations, or hidden queue growth. Keep recovery on video only; preserve control/input cleanup and bounded timeouts.

**Measurement.** Add refusal subtype logging. Under injected stalls plus repeated client requests, target **zero recovery IDRs when the reference chain remains intact**, and at most one active recovery IDR when it genuinely breaks. Check `idr_cause_*`, `idr_deferred`, `queue_drops`, `overwritten`, catch-up counters, and recovery time. Test the combined controller/encoder/queue/sender loop; replaying fixed historical TCP samples cannot validate feedback stability.

**3. Test short encoder rate windows before writing a socket pacer**

**Problem/evidence.** Current `DataRateLimits` permits twice the average bitrate over one second: **15 MB at 60 Mbps**. A 490–884 KB IDR fits easily. An existing knob adds a shorter window. [EncoderSubmitOrder.swift:96](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeCore/Video/EncoderSubmitOrder.swift:96).

**Proposed change.** A/B `MATEBRIDGE_RATE_WINDOW_MS` unset versus **50 ms**, then **33 ms** if useful. Explore 17 ms only if quality/output remain healthy.

| Window | Budget at 60 Mbps | Budget at 30 Mbps |
|---|---:|---:|
| 50 ms | 750 KB | 375 KB |
| 33 ms | 495 KB | 247.5 KB |
| 17 ms | 255 KB | 127.5 KB |

These are configured rate-window budgets, **not a measured guarantee of per-frame size**.

**Expected gain—inference.** Reduce scene-change and recovery bursts, shortening their cost when TCP’s congestion window has collapsed.

**Risks.** Worse transient quality, encoder drops, or delayed output. Do not use lower `MaxAllowedFrameQP` as a size cap: it demands better quality and can work against the goal. The earlier research’s suggestion on this point is misleading.

**Measurement.** Keep bitrate adaptation off for this experiment. Compare `idr_bytes_max`, per-frame `bytes/key` latency traces, encoder drops/time, `write`, `cap_to_sent`, presentation gaps, and visible scene-change quality. Then test the winning setting with adaptation. Effort **S**, unchanged protocol and input behavior.

**4. Verify DSCP on the actual Ethernet→AP path**

**Problem/evidence.** Service classes already exist, but the code records that Ethernet service-class metadata may not produce DSCP. Explicit TOS remains an unverified separate experiment. `MATEBRIDGE_IP_TOS=ef` means video **AF41**, control/audio **EF**. [TransportKnobs.swift:70](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeCore/Session/TransportKnobs.swift:70).

**Proposed change.** First verify emitted packet markings, including the dual-stack IPv4 case. Then compare off versus `ef` under the same controlled contention. Packet marking proves only marking; AP/WMM treatment still needs measurement.

**Expected gain—inference.** Potentially protect audio/control and improve video scheduling during contention. It will not repair radio loss or the IDR loop.

**Risks.** AP-dependent mapping and unexpected prioritization. No queue, input-state, or protocol changes.

**Measurement.** Separate this A/B from adaptation. Compare both sockets’ SRTT, video retransmissions/presentation gaps, audio OWD/underruns, and input latency. Effort **S**; uncertain benefit.

**5. Only pace socket bytes if residual burst evidence warrants it**

**Problem/evidence.** Writes currently drain available record bytes through `Darwin.write`; `TCP_NOTSENT_LOWAT` gates readiness, not total outstanding bytes or maximum frame size. Prior 64/128/256 KiB low-water experiments were inconclusive. [BsdTcpSocket.swift:580](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeCore/Session/BsdTcpSocket.swift:580), [NOTES:643](/Users/burakakcan/Desktop/matebridge/docs/NOTES.md:643).

**Conditional proposal.** If large bursts still correlate with receiver gaps after proposals 1–3, trial a video-only token-bucket writer with **16–32 KiB chunks**, one record in progress, and a small bounded burst allowance. Start above the encoding target—e.g. **1.25× target**—and measure the latency tradeoff.

Do not enlarge `SO_SNDBUF` to conceal congestion. Do not shrink it blindly either: it can restrict throughput and make whole-frame delivery slower.

**Expected gain—inference.** Less AP/kernel burst pressure. The tradeoff is real: at exactly 60 Mbps, serializing 490–884 KB already takes approximately **65–118 ms**. Pacing cannot make an IDR arrive earlier than an uncongested faster burst.

**Risks.** Additional frame latency, timer overhead, write-order errors. Never abandon partially written authenticated records; never apply this pacing to control/input/audio.

**Measurement.** Compare sender write duration, socket backlog, receiver interarrival gaps, `cap_cb_*`, control RTT, and audio underruns. Reject a change that merely moves buffering into userspace. Effort **M**, protocol unchanged.

**6. T-373 LTR: validate feasibility, then consider a protocol extension**

**Problem/evidence.** The previous HEVC probe found LTR unsupported in the current fast session and accepted with low-latency rate control. However, the cited 9–13 ms encoding cost was measured at **2800×1840**, not 1848×1214@60; it does not by itself disqualify this game mode. [forced-IDR research:33](/Users/burakakcan/Desktop/matebridge/docs/research/2026-10-23-forced-idr-chain.md:33).

**Proposed change.**

1. Benchmark fast versus low-latency rate control at the actual game resolution/rate.
2. Validate actual HEVC LTR recovery on the HiSilicon decoder, including skipped short-term references, decoder flush, reconnect, and reset.
3. Only then design negotiated token/frame mapping, receiver acknowledgement, and an explicit LTR-recovery indication.

Apple’s documented mechanism uses acknowledged LTR tokens and `ForceLTRRefresh`; without an acknowledged reference it falls back to IDR. Its original presentation concerns H.264, so HEVC support must rest on the platform probe and device validation. [Apple’s LTR explanation](https://developer.apple.com/videos/play/wwdc2021/10158/?time=435).

**A protocol change is necessary for robust LTR use.** Aggregate STATS cannot acknowledge an exact reference. TCP acknowledgement or host write completion does not establish that the decoder retained it. Tokens and acknowledgements must be scoped to connection/config/decoder generation, and cleared after decoder reset. Current keyframe-waiting logic must recognize valid LTR recovery without falsely labelling an LTR-P as an IDR.

No public arbitrary-reference-invalidation API was found in the inspected VideoToolbox headers. Do not assume arbitrary P-frame dropping becomes safe merely because frame reordering is disabled.

**Expected gain—inference.** Smaller recovery frames after genuine reference loss. **It cannot bypass missing bytes already blocking the TCP stream.**

**Risks.** Unverified HEVC/HiSilicon behavior, stale reference acknowledgements, encoder latency/quality regression, and substantial protocol drift. This needs an orchestrator-owned decision, Swift/Kotlin changes, and golden fixtures on both sides. Effort **L** overall.

**Lower-priority codec and client ideas**

- **Shorter GOP / slices:** do not prioritize. More frequent IDRs add bursts. Existing slice experiments found one callback per frame and no useful latency gain; HiSilicon did not advertise partial-frame support. Current authentication/framing also requires a complete video record. [NOTES:733](/Users/burakakcan/Desktop/matebridge/docs/NOTES.md:733).
- **Intra refresh:** the inspected public VT API did not establish a usable HEVC control; private `PeriodicRefreshMode` remains unvalidated. Android’s [`KEY_INTRA_REFRESH_PERIOD`](https://developer.android.com/reference/android/media/MediaFormat#KEY_INTRA_REFRESH_PERIOD) is encoder-only and cannot enable it on this decoder.
- **Client jitter/presentation:** current pacing is already adaptive and bounded; at 60/60 its normal delay cap is one panel interval. Increasing buffering cannot conceal 150–600 ms TCP stalls without imposing comparable input latency. Investigate the unexplained client-only drop episodes from NOTES using `late_drops`, `d_jitter_us`, `d_cap_us`, `skip_pct`, and callback gaps before changing pacing. [PacerTuning.kt:7](/Users/burakakcan/Desktop/matebridge/client-android/app/src/main/kotlin/dev/matebridge/client/video/PacerTuning.kt:7), [NOTES:2060](/Users/burakakcan/Desktop/matebridge/docs/NOTES.md:2060).
- **Audio:** the synchronization dependency is video latency→audio target, not audio→video blocking. Monitor audio OWD, underruns, safety buffer, and A/V offset; current evidence does not justify changing that path. [MainActivity.kt:2109](/Users/burakakcan/Desktop/matebridge/client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt:2109).
- **Panel/source cadence:** retain 1848×1214@60 for gamepad use. Huawei’s touchless 120 Hz attempts failed; touch-triggered refresh transitions can themselves disturb pacing. Moreover, 1302/1704 low-client-fps seconds in the long TotK run already had low host capture cadence. Network changes cannot supply frames the game did not produce. [NOTES:1999](/Users/burakakcan/Desktop/matebridge/docs/NOTES.md:1999).

**Device validation required for these proposals**

Use [T-364’s `game-ab.sh` / `game_ab.py`](/Users/burakakcan/Desktop/matebridge/tools/measure/README.md:136): alternate baseline/candidate for at least three 100-second arms each, same TotK location/camera motion, with applied size/fps/chroma/transport verified by `arm_check`. For adaptation, configured bitrate remains the ceiling; verify effective rate separately through `adapt`, `bitrate_set`, and `sent_kbps`.

Use [T-366’s `stall-inject.sh`](/Users/burakakcan/Desktop/matebridge/tools/measure/README.md:176) for repeatable 60 ms and separately 200 ms interruptions. Its documentation still says actual pf/dummynet operation was not device-verified. Because the tablet is the only display, the first live trial should be one bounded video-only interruption with cleanup/status verified, not an unattended batch. A 60 ms bandwidth restriction mostly queues packets; require observed retransmissions/cwnd collapse before claiming it reproduces radio-loss recovery.

Collect three complementary outcomes:

| Outcome | Existing evidence |
|---|---|
| Network and controller | `srtt_ms`, `rttvar_ms`, `retx_pkts_delta`, `tx_pkts_delta`, `snd_cwnd`, `sndbuf_bytes`, `user_pending_bytes`, `adapt_step`, `target_kbps`, `sent_kbps` |
| Recovery amplification | `idr_cause_*`, `idr_bytes_max`, `idr_coalesced`, `idr_deferred`, `queue_drops`, `overwritten`, per-event recovery time |
| Actual smoothness | `shown_*`, `cap_cb_*`, `skip_pct`, `hold_long_pct`, `late_drops`, `render_cb_missing`, catch-up counters, plus `cap_fps` |

The existing “>150 ms stall” statistic counts **one-second samples whose mean capture→decode exceeds 150 ms**. It misses some visible freezes and excludes presentation latency. Add presentation-gap counts/durations from existing callback/PaceTrace data to the report; treat callbacks as a presentation proxy, not a photon measurement. [game_ab.py:11](/Users/burakakcan/Desktop/matebridge/tools/measure/game_ab.py:11).

Acceptance should require: no self-generated recovery chain, bounded queues throughout, no healthy-path latency regression, faster recovery after the imposed impairment ends, and improved presentation gaps on genuinely bad WLAN days. A 200 ms imposed outage cannot reasonably have a “no >150 ms visible freeze” acceptance criterion.