# Backlog manifest: external architecture review (2026-10-03, HEAD a30c769) → cards and decisions

Built from `claims.md` and the reports in this scratchpad: `verify-A-security`, `verify-A2-adversarial`, `verify-B-client-video`, `verify-C-host-video`, `verify-D-display`, `verify-E-measurement`, `verify-F-network`, `verify-G-input` and `verify-H-hygiene`. Report items are cited as "A WI-1", "B P2", "D P-3" and so on.

## Conventions

- **IDs.** New cards run **T-145 … T-203**. T-127 keeps its ID and is re-scoped. The former migration-gate card was folded into T-150 (coverage audit), and later cards were renumbered.
- **Decision numbers.** New decisions run **0018 … 0028**, numbered in development order (trust 0018 → video health 0019 → display lifetime 0020 → latency semantics 0021 → others) per the coverage audit K1. Every report that proposed "0018" or "0019" has been renumbered here; quoted report-local numbers such as `("0018")` refer to the source drafts. The table in §1 is authoritative.
- **R-tagged findings.** M01, M02, M03, M06 and L03 are "inferred risk" findings (review p11). Their cards start with a deterministic failing scenario or test, committed red before the fix: T-160 (M01), T-162 step 1 (M02), T-161 (M03), T-147/T-148 (M06), and T-175 (L03, measurement first).
- **Phase.** Every new card has `phase: 6`, the new PLAN phase "Güvenilirlik ve ölçüm" that the orchestrator will add. T-127 moves from phase 5 to phase 6.
- **Status.** Every card has `status: todo`. A card with a `decisions:` entry carries this note in *Amaç*: "decision NNNN must be accepted by the user first".
- **Order.** Cards are listed in development order:
  - D1 baseline → D2 trust → D3 video health and input safety → D4 display → D5 measurement → D6 Wi-Fi → D7 pen → D8 profiles → D9 scope and setup → D10 soak.
  - The trailing **G block** holds measurement-gated or low-value items. Each one names the measurement that unlocks it.
- **Wire column.**
  - `none`: no change to PROTOCOL.md or the fixtures.
  - `prose-only`: the orchestrator edits PROTOCOL.md text. No bytes or fixtures change, and `gen.py --check` stays green.
  - `wire`: messages or fields change, so PROTOCOL.md, `protocol/fixtures/` and both fixture tests change.
  - No card is unconditionally `wire`. Two cards are wire only if a later decision picks the wire option (T-172 option B, T-180 tilt sign).
- **Codex.** Run `./scripts/codex-review.sh` for protocol, input-state, pen-injection and security changes, as CLAUDE.md requires.
- **Path abbreviations.** Card writers expand these. Every path below exists at HEAD unless it is marked *(new)*.
  - `C/` = `client-android/app/src/main/kotlin/dev/matebridge/client/`
  - `CT/` = `client-android/app/src/test/kotlin/dev/matebridge/client/`
  - `CR/` = `client-android/app/src/main/res/`
  - `HC/` = `host-mac/Sources/MateBridgeCore/`
  - `HH/` = `host-mac/Sources/MateBridgeHost/`
  - `HA/` = `host-mac/Sources/MateBridgeApp/`
  - `HT/` = `host-mac/Tests/MateBridgeCoreTests/`
- **Test markers.**
  - [JVM] = client unit test under `./scripts/check.sh`.
  - [XCTest] = host Core test.
  - [device] = real Mac and/or tablet, run by the orchestrator one at a time, per CLAUDE.md.
- **Card file.** Every card's `files:` list also includes its own card file. It is omitted below for brevity.

---

## 1. Decision records

All are drafted with status **önerildi** and need the user's acceptance. The "Draft text" column says where the draft wording is.

| No | Slug | Title | Draft text | Gates |
|---|---|---|---|---|
| 0018 | `tablet-trust-confirmation` | Tablet-side trust confirmation and user-initiated pairing | A WI-0, amended by A2 | T-150, T-151, T-153, T-156 |
| 0019 | `video-health-input-gate` | Input is live only while video is healthy | B P1 | T-159, T-161 |
| 0020 | `virtual-display-lifetime` | Virtual display lifetime is separated from the session (parked display) | D P-1 | T-167, T-200 |
| 0021 | `capture-timestamp-semantics` | Meaning of `capture_time_us` and of the latency numbers | C LM4-D + E W4 (merged) | T-172 |
| 0022 | `ci-github-actions` | CI on GitHub Actions as the merge gate | H CI-1 | T-149 |
| 0023 | `wifi-congestion-control` | Wi-Fi congestion handling stays on TCP: fixed Wi-Fi profile first, then in-flight budget and live bitrate | F F-0 + F F-7 (merged) | T-178, T-195, T-196 |
| 0024 | `wifi-pen-playout` | Experimental bounded pen playout on Wi-Fi | G P-M04c ("0018") | T-198 |
| 0025 | `stale-input-policy` | Stale input after network stalls | G P-M04d ("0019") | T-199 |
| 0026 | `experiment-knobs` | Experiment knob policy and classification | H KNOB-0 ("0019") | T-182 … T-186 |
| 0027 | `usb-only-network-profile` | Host "Yalnız USB" network profile | A WI-5 | T-189 |
| 0028 | `tablet-files-scope` | Tablet file sharing: chosen folder and read-only (amends 0015) | A WI-6 | T-190 |

**Amendments to existing decisions** (no new number; the orchestrator edits them):
- **0010:** status note → "kısmen 0018 ile değişti".
- **0003:** new KEY repeat stop condition (T-163).
- **0015:** item 1 is superseded by 0028.
- **0013:** a Wi-Fi bitrate default is added by 0023.
- **0016:** text nit. Only refresh changes recreate the display (D additional 7).
- **0006:** amended only if T-203 is adopted.

**Deferred decisions** (no number until drafted):
- Latency budgets (B1), after T-174.
- Host crash restart through a LaunchAgent, only if T-147 shows a need (T-202).
- Fallback when `CGVirtualDisplay` is unavailable (D P-9). Not carded; see §4.

### 0018 — Tablet-side trust confirmation (A WI-0; A §H01/D2 corrections; A2 §1–2)
- **Context:** the tablet stores a new pair key at the first PAIRING ack (T-044) and accepts any sealed ACCEPTED. As a result:
  - any endpoint that answers PAIRING gets input, clipboard (both directions) and the FILES_INFO token. This includes a Bonjour or remembered-IP impostor on Wi-Fi, and a local app squatting `127.0.0.1:47001`;
  - an impostor using the same host_id overwrites the stored key, which causes an endless PROTOCOL_ERROR loop.
- **Options:**
  - (a) status quo;
  - (b) commit the key only when local confirmation AND the host's ACCEPTED are both present (the review's wording). This breaks the Parsec/orphan flow the user relies on;
  - (c) **recommended:**
    - The new key is kept as a **pending** record (key + SAS). **Local confirmation** of the code promotes it atomically.
    - The session is ACCEPTED on the tablet only when the host accepts (ACCEPTED, or a later PAIRED handshake) AND the record is locally trusted.
    - Cancel, timeout or REJECTED drops the pending key. A PAIRED handshake never uses an unconfirmed pending key.
    - A PAIRING answer on a connection the user did not start (discovery, saved endpoint, USB probe) is aborted and surfaced as "Yeni Mac bulundu / Mac yeniden eşleşmek istiyor — Eşleş". **Pairing is always user-initiated** (A2 addition).
    - "Bu Mac'i unut" is added on the tablet.
- **Wire:** prose only, PROTOCOL §3 step 3 and §9 ("Eşleşme" bullets 1/3, "Bağlantı koptuktan sonra onay" (1)/(3)). No fixtures change.

### 0019 — Video health gates input (B P1)
- **Options:**
  - (a) status quo: give-up is only logged;
  - (b) a blind "no frame for N s" watchdog. Rejected, because a static screen legitimately sends no frames;
  - (c) **recommended:** an explicit `VideoHealth` state. Input capture is active only while the video is HEALTHY. HEALTHY means a surface is attached, the current decoder generation has produced at least one output, and no fault is set.
- **Faults:**
  - give-up;
  - no decoded output for 1500 ms while at least 3 non-config frames were queued (the T-028 class);
  - the decoder thread is not running 2 s after attach, or the teardown wait times out (M03).
- **On a fault:**
  - capture is turned off (the existing `RELEASE_ALL(USER)`; no wire change);
  - feeding stops, and keyframe retries stop;
  - an overlay is shown;
  - recovery runs in this order: codec restart at 1 s → at 3 s → session reconnect → "Yeniden dene".
- A new session or config generation opens input only after its first decoded output.

### 0020 — Virtual display lifetime (D P-1)
- **Options:**
  - (a) status quo: 10 s grace, during which capture and encode keep running;
  - (b) keep the display until Quit;
  - (c) **recommended:** park the display when a session ends.
    - Input is released, capture, encode and audio stop, and display identity, size and refresh are kept.
    - Removal happens on: the keep time expiring (choices 10 s / 5 min / 30 min / until Quit), "Sanal ekranı şimdi kaldır", a different device or size, a refresh change, or host quit.
- **Lifetime limit:** the honest lifetime is "host process, bounded by preference". A display cannot outlive the host.
- **Default keep time:** chosen by the user **after T-166**. The key unknown is whether a retained display survives display sleep and system sleep.
- **Keep timer clock:** must use a continuous clock if wall time is intended (D additional 5).

### 0021 — Capture-timestamp semantics (C LM4-D, E W4)
- **Fact:** the wire `capture_time_us` is the SCK PTS. That is about 6.6 ms *after* the host's trace origin (the SCK callback), so the tablet "latency" under-reports. The tablet pacer and A/V sync depend on the current stamp.
- **Options:**
  - (A) **recommended if T-170 data shows `pts_vs_deliv` p99−p1 < 1 ms:** no wire change. Tablet numbers are named "capture-stamp→…", and analysis adds the host-logged lead.
  - (B) append `origin_offset_us: i32` after `data` in `VIDEO_FRAME` (allowed by §2). This needs a new golden vector and both fixture tests. It is **wire**, with follow-up cards.
- **Either option:** the §0x22 and §6 text "→ ekranda gösterim" is corrected to "decoder output".

### 0022 — CI on GitHub Actions (H CI-1)
- **Options:** (a) keep only the manual local `check.sh`; (b) GitHub-hosted macOS and Linux jobs that run `check.sh` split by component; (c) a self-hosted runner on the Mac mini.
- **Recommended:** (b).
  - The macOS job runs host plus protocol checks, and only on path filters to save billed minutes. The Linux job runs Android `assembleDebug testDebugUnitTest` plus the protocol checks.
  - It is advisory for the first week, then required.
  - Hardware paths (SCK, VT, CGVirtualDisplay, MediaCodec, AAudio, TCC) are explicitly not covered.
  - Only first-party `actions/*` and `actions/setup-java` are used.
- **User choice needed:** none on cost — the repo is public (docs/WORKFLOW.md), so GitHub-hosted macOS minutes are free; user only confirms adopting CI as a merge gate.

### 0023 — Wi-Fi congestion control (F F-0, F F-7)
- **Context:**
  - The delay comes from queueing, not loss. Video bursts of 100–450 KB raise control srtt from 20 ms to 60–100 ms and cause audio underruns, despite AC_VO/AC_VI marking.
  - Only kernel *unsent* bytes are bounded; in-flight bytes are not.
  - Bitrate is fixed per session, and changing it restarts the pipeline.
- **Options:**
  - (a) go to UDP or QUIC now. Rejected (A3/A4).
  - (b) **step 1:** a host-only fixed conservative Wi-Fi default bitrate (amends 0013; no wire change), used if the T-127 baseline shows it is enough.
  - (c) **step 2, only if (b) is not enough:** bound video in-flight bytes with an `sbbytes` budget and adapt bitrate live (fast-down, slow-up) through `VTSessionSetProperty`, never through the restart path. `STREAM_CONFIG.bitrate_kbps` then means "ceiling" (§0x03 prose only).
- **Revisit trigger:** datagram transport is reconsidered only if retransmission-driven p99 still dominates afterwards.
- **Updates:** PLAN.md:74 and :126.

### 0024 — Wi-Fi pen playout, experimental (G P-M04c)
- **Options:**
  - (a) no playout. This is today's state and the user's "acele yok, en sona" (PLAN Aşama 5).
  - (b) host playout of PEN samples by their `dt_us`, at most 12 ms added, non-loopback only, behind `MATEBRIDGE_PEN_PLAYOUT_MS` (default 0). Every state boundary flushes immediately.
  - (c) also rewrite CGEvent timestamps. Rejected: NOTES shows Krita's timestamp option did not help.
- **Recommended:** (b), as an experiment only. It is adopted as the default only if a Wi-Fi A/B shows a line-quality gain that outweighs the latency. Gated on T-179.

### 0025 — Stale input policy (G P-M04d)
- **Policy:** input whose host-measured age exceeds T_stale (initially 300 ms; set from T-171 data) is handled as follows.
  - Hover and relative motion collapse to the newest state.
  - New presses are ignored together with their matching releases: STROKE_START, button-down, KEY DOWN, SCROLL/PINCH BEGAN.
  - Releases are always applied.
  - The policy is off (fail-open) when the clock offset is untrustworthy.
- **Option rejected:** client-side keepalives for held keys.
- **Wire:** prose only, §4 "Kabul edilen davranış" and §7. Gated on T-171 data.

### 0026 — Experiment knobs (H KNOB-0)
- **Rules:**
  - Every knob is listed in `docs/KNOBS.md` with its card, default, class (keep / debug-only / retire) and outcome.
  - New knobs default to off and name their closing card.
  - Client debug-only extras are honoured only with `--ez dev true`. The daily APK is the debug variant, so a build-type split is not enough.
  - Each side logs one `ev=profile` line at session start.
- **Retire:** GL presentation (T-018/T-019), `nw` sockets (T-091/T-111), idle refresh (T-086/T-087), perf hint, refresh vote, the cpd pacer, the inflight limit, oprate, keep_jitter/recenter, crypto bench, FRAME_DELAY, PRIO_SPEED, H264_PROFILE and INPUT_RETAG=0. T-019 and T-067 close as won't-do.
- **Not retired (audit K4):** client Wi-Fi TOS/`wifi_ll`/WifiLock knobs stay debug-only until T-127 re-measures them under `bsd`. Their 2026-10-01 "no effect" result was confounded by the `nw` ceiling.
- **User confirmation needed:** GL and `nw` retirement.

### 0027 — USB-only network profile (A WI-5)
- **Options:** (a) all interfaces always; (b) per-interface selection; (c) **recommended:** an optional "Yalnız USB" mode.
- **In that mode:**
  - the control and video listeners bind loopback only;
  - there is no Bonjour advertisement;
  - non-loopback peers are refused at accept;
  - Wi-Fi fallback and the wake flows (T-133/T-134) are unavailable.
- **Default:** stays "USB + Wi-Fi". §3.1 gets prose saying Bonjour may be absent.

### 0028 — Tablet files scope (A WI-6, amends 0015 item 1)
- **Options:** (a) whole shared storage (today); (b) **recommended:** a user-chosen folder, with an optional "tüm depolama" choice and an optional read-only mode.
- **Lifetime:** server lifetime is already narrowed in T-153 without a decision. FILES_INFO is unchanged.

---

## 2. Card table (in order)

The first table gives ID, owner, depends_on and decisions. The second gives slug, title, wire, source, review IDs and goal for the same rows, in the same order.

### 2a. ID, owner, depends_on, decisions

| ID | Owner | depends_on | decisions |
|---|---|---|---|
| **D1 — Safe baseline** | | | |
| T-145 | mac-host-dev | [] | [] |
| T-146 | android-client-dev | [] | [] |
| T-147 | orchestrator (user rehearses) | [T-145, T-146] | [] |
| T-148 | mac-host-dev | [] | [] |
| T-149 | orchestrator | [] | [0022] |
| **D2 — Trust boundary** | | | |
| T-150 | android-client-dev | [T-042, T-044] | [0018] |
| T-151 | android-client-dev | [T-150] | [0018] |
| T-152 | mac-host-dev | [T-041] | [] |
| T-153 | android-client-dev | [T-151] | [0018] |
| T-154 | android-client-dev | [] | [] |
| T-155 | mac-host-dev | [T-152] | [] |
| T-156 | android-client-dev | [T-151] | [0018] |
| T-157 | orchestrator + user | [T-150, T-151, T-152, T-153, T-155] | [0018] |
| **D3 — Video health and input safety** | | | |
| T-158 | android-client-dev | [] | [] |
| T-159 | android-client-dev | [T-158] | [0019] |
| T-160 | android-client-dev | [T-159, T-150] | [] |
| T-161 | android-client-dev | [T-159, T-160] | [0019] |
| T-162 | mac-host-dev | [] | [] |
| T-163 | mac-host-dev | [] | [] (amends 0003) |
| T-164 | orchestrator + user | [T-159, T-161] | [] |
| **D4 — Display decoupling** | | | |
| T-165 | mac-host-dev | [] | [] |
| T-166 | user (procedure: orchestrator) | [T-165, T-147] | [] |
| T-167 | mac-host-dev | [T-165, T-166] | [0020] |
| **D5 — Measurement** | | | |
| T-168 | android-client-dev | [T-161] | [] |
| T-169 | android-client-dev | [T-168] | [] |
| T-170 | mac-host-dev | [T-162] | [] |
| T-171 | mac-host-dev | [T-152, T-163] | [] |
| T-172 | orchestrator | [T-170] | [0021] |
| T-173 | orchestrator | [T-145, T-146] | [] |
| T-174 | user (procedure: orchestrator) | [T-168, T-173] | [] |
| T-175 | mac-host-dev | [T-171] | [] |
| **D6 — Wi-Fi** | | | |
| **T-127** (re-scope) | orchestrator + user | [T-126, T-168, T-170, T-173] | [] |
| T-176 | mac-host-dev | [T-162] | [] |
| T-177 | mac-host-dev | [T-162, T-176] | [] |
| T-178 | mac-host-dev | [T-127] | [0023] |
| **D7 — Pen** | | | |
| T-179 | orchestrator + user | [T-171, T-127] | [] |
| T-180 | orchestrator + user | [] | [] |
| T-181 | orchestrator | [] | [] |
| **D8 — Profiles and simplification** | | | |
| T-182 | orchestrator | [] | [0026] |
| T-183 | android-client-dev | [T-182, T-168] | [0026] |
| T-184 | android-client-dev | [T-183] | [0026] |
| T-185 | android-client-dev | [T-184, T-146] | [0026] |
| T-186 | mac-host-dev | [T-182, T-177, T-171] | [0026] |
| T-187 | mac-host-dev | [T-186] | [] |
| T-188 | user (procedure: orchestrator) | [] | [] |
| **D9 — Scope, setup, docs** | | | |
| T-189 | mac-host-dev | [T-186] | [0027] |
| T-190 | android-client-dev | [T-153] | [0028] |
| T-191 | android-client-dev | [T-185] | [] |
| T-192 | mac-host-dev | [T-167, T-189] | [] |
| T-193 | orchestrator | [T-145, T-146, T-147] | [] |
| **D10 — Soak** | | | |
| T-194 | user + orchestrator | [T-173, T-157, T-164, T-167, T-193] | [] |
| **G — Measurement-gated or low value** | | | |
| T-195 | mac-host-dev | [T-127] | [0023] |
| T-196 | mac-host-dev | [T-177, T-195] | [0023] |
| T-197 | android-client-dev | [T-127] | [] |
| T-198 | mac-host-dev | [T-179, T-171] | [0024] |
| T-199 | mac-host-dev | [T-171, T-175] | [0025] |
| T-200 | mac-host-dev | [T-165, T-166] | [0020] |
| T-201 | mac-host-dev | [T-188] | [] |
| T-202 | mac-host-dev | [T-147] | [deferred] |
| T-203 | android-client-dev | [T-181] | [0006 amend] |

### 2b. Slug, title, wire, source, review IDs, goal

| ID | Slug | Title | Wire | Source | Review IDs | Goal |
|---|---|---|---|---|---|---|
| **D1** | | | | | | |
| T-145 | `host-build-identity` | Log and show the host build commit | none | H BUILDID-H | L01, D1, M07 | Every host log and menu shows SHA and build time. |
| T-146 | `client-build-identity` | Log and show the client build commit | none | H BUILDID-C | L01, D1, M07 | Every client log and the settings panel show SHA and build time. |
| T-147 | `recovery-runbook` | Write and rehearse the recovery runbook and known-good version pair | none | D P-7 | M06, SE5, F5, D1, X13 | Give a tested way to reach the Mac when the tablet shows nothing. |
| T-148 | `host-login-item-retry` | Retry login-item registration after a failure | none | D P-6 | M06 | A failed registration must not block retries forever. |
| T-149 | `ci-merge-gate` | Add a component-split CI merge gate and a safe fixture CLI | none | H CI-1 + H add. 1, 2 | M07, P4 | Make the local gate reproducible per commit; `gen.py` must never rewrite fixtures by accident. |
| **D2** | | | | | | |
| T-150 | `client-pending-pair-trust` | Keep new pair keys pending until local confirmation; pair only on user action; gate migration promotion on an authenticated record | prose-only (§3, §9) | A WI-1, A2 §1–2 + A2 migration side finding | H01, X1, D2, F2, SE2, W3, A2(iii) | Stop an impostor from getting input, clipboard or the token, or overwriting the key. |
| T-151 | `client-trust-ui` | Add pairing confirm/cancel, the new-host pick prompt and "Bu Mac'i unut" | none | A WI-2, A2 §1 | H01, D2 | Give the user the explicit pick and SAS confirmation that T-150 requires. |
| T-152 | `host-paired-proof-first` | Activate PAIRED sessions only after the first authenticated record | prose-only (§3) | A WI-3, A2 §3 | SE2, W3 (A1) | Stop pre-auth display creation, wake and display-sleep hold. |
| T-153 | `client-files-session-lifetime` | Run the WebDAV server only during an accepted, trusted USB session | none | A WI-6 (lifetime part), A A4 | M05 | Shrink the window in which the token-protected listener exists. |
| T-154 | `client-data-extraction-rules` | Exclude app data from device-to-device and cloud transfer | none | A A5, A2 §4 | SE1 | Make the backup policy match `allowBackup=false` on targetSdk 31. |
| T-155 | `host-orphan-approval-guard` | Flag a replaced orphan approval request on the Mac | none | A A6, A §M05 corr. 3 | M05 (approval surface) | Reduce approval fatigue: a swapped request must be visibly different. |
| T-156 | `client-key-mismatch-state` | Show "anahtar uyuşmuyor" after repeated PAIRED auth failures | none | A WI-7, A A3 | H01 (DoS residue) | Replace the endless PROTOCOL_ERROR loop with an actionable state. |
| T-157 | `trust-device-acceptance` | Run the trust-transition device acceptance (X1) | none | A WI-4 | X1, H01, D2 | Device evidence that the trust boundary holds; merge gate for D2. |
| **D3** | | | | | | |
| T-158 | `client-decoder-backend-seam` | Put MediaCodec behind a DecoderCodec interface (no behaviour change) | none | H TESTSEAM-1 (client), B X3 corr. | M07 (seam), X3, X6 | Prerequisite for the deterministic H02/M03 tests. |
| T-159 | `client-video-health-gate` | Gate input on decoder health and show a video-fault overlay | none | B P1 + B add. 1, 2, 5 | H02, SE4, X3, D3, F2 | A frozen or black image must never keep input live. |
| T-160 | `client-video-delivery-gate` | Drop video frames from stale connections and uninstalled configs | none | B P2 + B add. 4 | M01, X4, SE3, D3 | No wrong-generation frame reaches the decoder (closes the T-028 ordering). |
| T-161 | `client-decoder-teardown-bounds` | Bound the decoder hand-off, join the output thread, keep per-generation state | none | B P3 + B add. 3 | M03, SE7, X6, D3 | No unbounded join, no straggler shared state, no thread pile-up. |
| T-162 | `host-encoder-submit-owner` | Serialise HEVCEncoder submits, QP updates and teardown on one owner queue | none | C M02-H + C add. 1–6, H TESTSEAM-1 (host) | M02, X5, SE7 | Monotonic PTS at the VT boundary; no submit after invalidate. |
| T-163 | `host-key-repeat-stall-pause` | Pause host key auto-repeat while the control connection is silent | prose-only (§4 KEY) | G P-KR | M04 (freshness), X2 | A delayed KEY UP during a stall must not produce ghost repeats. |
| T-164 | `video-fault-churn-device-run` | Run decoder fault injection and the surface-churn soak on the tablet | none | B P4, H add. 6 | X3, X6, D3 | Device evidence that faults release input and resources return to baseline. |
| **D4** | | | | | | |
| T-165 | `host-park-virtual-display` | Park the virtual display after a session ends (no capture or encode while parked) | none | D P-2 | H04, A1, F2, D4 | Idle cost ~0 during the keep window; the keep time becomes cheap to raise. |
| T-166 | `parked-display-measurement` | Measure parked-display behaviour across sleep, lock and long outages | none | D P-3, D add. 2, 6 | X7, H04 | Settle the key unknown; pick the 0020 default; decide T-200. |
| T-167 | `host-display-keep-menu` | Add a display keep-time preference and "Sanal ekranı şimdi kaldır" to the menu | none | D P-4 | H04, D4 | User-controlled display lifetime plus an explicit recovery action. |
| **D5** | | | | | | |
| T-168 | `client-latency-stage-stats` | Break client latency into stages with percentiles; stop clamping; fix stats maps; log decoder hardware | none | E W1 + E add. 1, 4, 6 + audit PF7 | H05, LM2, LM5, LM6, D5, PF7 | Tablet numbers say what they measure: capture→decode, ready→slot, →release, →render callback. |
| T-169 | `client-refresh-target-log` | Log target and real refresh separately; warn on a mismatch | none | E W7 + E add. 5 | X12 | Every window shows requested vs actual panel Hz. |
| T-170 | `host-latency-trace-join` | Make the host latency CSV joinable with the tablet trace; fix labels | none | E W2 + E add. 2 | H05, LM4, LM8, D5 | Exact per-frame join on `pts_us == capture_us`; supplies data for 0021. |
| T-171 | `host-input-age-ping` | Measure input age at injection through host PING (diagnostics only) | prose-only (§6) | E W3 + G P-M04b (merged) + G add. 3 | M04, LM3, LM8, IN8 | Make input-path latency and Wi-Fi bunching visible without a wire change. |
| T-172 | `latency-semantics-docs` | Record decision 0021 and correct the latency and late-input prose | prose-only (wire only if 0021 = B) | C LM4-D, E W4, E add. 3, G add. 2 | H05, LM4, M04 | Stop docs claiming "to display"; state the real late-input bound. |
| T-173 | `measurement-kit-smoke` | Version the measurement and soak scripts and add `device-smoke.sh` | none | E W6 + H SOAK-1 tooling (merged) | M07, D5, D10 | Reproducible numbers; one command records build, codec, Hz, mode and transport. |
| T-174 | `optical-latency-baseline` | Record the optical input-to-photon baseline (USB/Wi-Fi, 60/120 Hz) | none | E W5 | LM3, B1, D5, H05 | First physical end-to-end numbers; residual vs software stages explained. |
| T-175 | `host-input-delivery-timing` | Time host input delivery, environment lookups and CGEventPost per message | none | F F-6 + G P-L03i (merged) | L03 (input), W4 Mac input | Quantify session-queue blocking and per-message OS-query cost before optimising. |
| **D6** | | | | | | |
| **T-127** | `wifi-video-burst-pacing` (keep slug) | **Re-scope:** measure the Wi-Fi baseline across 3 topologies before any congestion code | none | F "T-127 (re-scoped)", F A-5 | H03, X8, D6, A3, LM7 | USB / Mac Ethernet + tablet Wi-Fi / both Wi-Fi under the same workload, with budgets set beforehand. |
| T-176 | `host-drop-idr-feedback` | Stop forced-IDR feedback on host-side queue drops | none | F F-4 + F A-1, A-2 | H03 | No IDR storm under Wi-Fi back-pressure. |
| T-177 | `host-live-bitrate-setter` | Add a live encoder bitrate setter (no restart) and verify VT honours it | none | F F-1 + F A-3 | H03, A6 | Bitrate becomes a fast in-session lever. |
| T-178 | `host-wifi-default-bitrate` | Use a conservative default bitrate on Wi-Fi (host only) | none | F F-7 (host-only variant) | H03, D6, D8 | The cheap fixed Wi-Fi profile, if T-127 shows it is enough. **Gated on T-127.** |
| **D7** | | | | | | |
| T-179 | `pen-wifi-rhythm-measurement` | Measure Wi-Fi pen arrival rhythm after T-111 across 3 topologies | none | G P-M04a + G add. 5 | M04, D7, IN8 | Decide whether host playout (T-198) is worth doing. |
| T-180 | `pen-keyboard-validation-matrix` | Run the pen and keyboard device validation matrix | none (wire only if the tilt sign is wrong) | G P-PK | PK2, PK3, PK7, X2, X9, X10, D7, IN4 | Close the device gaps left by T-025. |
| T-181 | `palm-before-pen-measurement` | Measure palm-before-pen clicks and the touchMajor distribution | none | G P-PALM (measurement) | PK4, PK5 | Evidence before any palm filter. |
| **D8** | | | | | | |
| T-182 | `experiment-knob-inventory` | Record decision 0026 and the knob inventory; close T-019 and T-067 | none | H KNOB-0, F (T-019 superseded) | L02, F3, D8 | Freeze the classification before removing code. |
| T-183 | `client-retire-experiments` | Retire concluded client experiments (perf hint, rvote, cpd, …; Wi-Fi knobs kept) | none | H KNOB-C1, audit K4 | L02 | Remove dead branches from the daily video path. |
| T-184 | `client-retire-gl-path` | Retire the GL presentation path | none | H KNOB-C2 | L02, H02/M03 (surface paths) | One Surface lifecycle instead of two. |
| T-185 | `client-dev-knob-gate` | Gate debug extras behind `dev`; add `ev=profile`; move NetBench to debug | none | H KNOB-C3 + H add. 3, A A7 | L02, D8 | Knobs unreachable by accident or by other apps; profile line in every log. |
| T-186 | `host-retire-experiments` | Retire concluded host experiments (`nw` sockets, idle refresh, …); add `ev=profile` | none | H KNOB-H1 | L02, D8 | Smaller SessionServer; fewer encoder callers. |
| T-187 | `host-encoder-hw-warning` | Warn when VideoToolbox did not select the hardware encoder | none | C PF7-H | PF7, D8 | A software fallback becomes visible. |
| T-188 | `colour-range-check` | Check stream colour, range and chroma fidelity with test patterns | none | C PF6-M | PF6, X11, D8 | Explicit verdict on range and colour-text fringing; document the SDR/4:2:0 limit. |
| **D9** | | | | | | |
| T-189 | `host-usb-only-profile` | Add a "Yalnız USB" network profile | prose-only (§3.1) | A WI-5 | M05, D9 | Close the LAN listening and pairing surface when only USB is used. |
| T-190 | `client-share-folder-scope` | Share a chosen folder (optional read-only) instead of all storage | none | A WI-6 (scope part) | M05, D9 | The approved Mac reaches only the folder the user chose. |
| T-191 | `client-settings-reset` | Add "Varsayılanlara dön" (settings + learned audio state; pairing kept) | none | H RESET-C + H add. 4 | D9 | A known-good reset without "clear data". |
| T-192 | `host-settings-reset` | Add "Ayarları sıfırla" to the menu (approvals kept) | none | H RESET-H | D9 | Host known-good reset. |
| T-193 | `readme-plan-refresh` | Rewrite the README to the current state; refresh PLAN status; record the version pair | none | H DOC-1 + H add. 8, H §P1 | L01, P1, D9 | README becomes the single current-state page; PLAN stops misleading agents. |
| **D10** | | | | | | |
| T-194 | `soak-8h-week` | Run the 8 h soak, then one week of real use, with resource trends | none | H SOAK-1 (run), E W6 (procedure), D §X13 | D10, X13, M07, SE6 | Evidence for the "sole main screen" claim. |
| **G** | | | | | | |
| T-195 | `core-congestion-controller` | Write a pure Wi-Fi congestion controller (in-flight budget, fast-down/slow-up) | none | F F-2 | H03 | **Gated on T-127** showing that a fixed profile is not enough. |
| T-196 | `host-wifi-adaptive-send` | Wire the congestion controller into the video gate and the encoder (Wi-Fi, knob) | prose-only (§0x03 "ceiling") | F F-3 | H03, X8 | **Gated on T-127 and T-195.** |
| T-197 | `client-ctl-lowat-knob` | Experiment knob: TCP_NOTSENT_LOWAT on the client control socket | none | F F-5, F §IN11 | IN11, M04 | **Gated on T-127** (uplink stall evidence). |
| T-198 | `host-pen-playout-experiment` | Experimental bounded pen playout on Wi-Fi (knob, default off) | none | G P-M04c + G add. 4 | M04, D7 | **Gated on T-179** showing clustering remains. |
| T-199 | `host-stale-input-policy` | Apply the stale-input policy on the host | prose-only (§4, §7) | G P-M04d (implementation) | M04 | **Gated on T-171 age data** and 0025 acceptance. |
| T-200 | `host-display-keep-on-failure` | Keep a healthy display when capture or the encoder fails | none | D P-5 + D add. 1 | H04, F2 | **Gated on T-166** (does the display survive display sleep?). |
| T-201 | `host-chroma-bench` | Add an RGB-referenced chroma metric and test patterns to SharpnessBench | none | H IQ-1 | X11, PF6 | **Gated on T-188** being inconclusive by eye. |
| T-202 | `host-crash-restart-agent` | Relaunch the host after a crash (LaunchAgent with KeepAlive) | none | D P-8 | M06, SE5 | **Gated on T-147** rehearsal showing a need; decision to be drafted then. |
| T-203 | `client-palm-size-filter` | Contact-size palm filter | none | G P-PALM (implementation) | PK4, PK5 | **Gated on T-181** showing a separable distribution. |

### Sequencing notes

- **Shared files.** Some cards depend on others only because they edit the same files; BOARD rules forbid parallel in-progress cards on one file:
  - T-160 waits on T-150 (SessionController, SessionMachine);
  - T-153 waits on T-151 (MainActivity);
  - T-171 waits on T-152 and T-163 (SessionMachine.swift, SessionServer, InputController);
  - T-177 waits on T-176 (VideoPipeline, HEVCEncoder);
  - T-186 waits on T-177 and T-171;
  - T-187 waits on T-186.
- **T-150 and T-151** must merge back-to-back. T-150 alone makes every auto-connect PAIRING abort, and the UI to recover arrives in T-151. Do not install an APK between them.
- **Can start at once in parallel** (no shared files): T-145, T-146, T-148, T-149, T-152, T-154, T-158, T-162, T-163, T-165, T-180, T-181, T-182.

### Serialize-with chains (hot files; coverage audit §4.5)

The orchestrator must not have two cards from the same chain in-progress at once. The listed order is the default; cards outside the chain may interleave. Where a link is not already a `depends_on`, the card writer adds a line to *Plan*: "Serialize with T-xxx (same file)".

| Hot file | Chain (default order) | Notes |
|---|---|---|
| `HH/Video/HEVCEncoder.swift` | T-162 → T-170 → T-176 → T-177 → T-186 → T-187 | The audit prefers knob retirement first, to shrink the encoder surface. If 0026 is accepted before T-162 starts, T-186's encoder part may run first and T-162 rebases. Default: safety fix first. The T-177 setter must go through T-162's owner queue. |
| `C/video/VideoRenderer.kt` | T-158 → T-159 → T-160 → T-161 → T-168 → T-183 → T-184 | T-161/T-164 GL churn applies only while the GL path exists (T-184 deletes it). T-183 compares stats using T-168's new names or their aliases. |
| `C/MainActivity.kt` | T-146 → T-151 → T-153 → T-159 → T-160 → T-168 → T-169 → T-183 → T-184 → T-185 → T-191 → T-197 | Most links are already `depends_on`. Add "serialize with" for T-159 after T-153, and T-197 after T-185. |
| `HH/Session/SessionServer.swift` | T-163 → T-171 → T-186 → T-189 → T-196 | T-186 removes the `nw` listeners before T-189 binds loopback (A WI-5's hints at :600/:987 are obsolete after T-186). |
| `HC/Session/SessionMachine.swift` | T-152 → T-155 → T-171 | Proof-first (security) lands before host PING; PING starts only after activation. |
| `C/session/SessionMachine.kt`, `SessionController.kt` | T-150 → T-156 → T-159 → T-160 → T-197 | T-159 touches SessionMachine.kt only for the frames-reset fix. |
| `HH/Input/InputController.swift` | T-163 → T-171 → T-175 → T-198 / T-199 | |
| `HH/Session/StreamCoordinator.swift` | T-165 → T-167 → T-187 → T-196 → T-200 | |
| `HA/main.swift` | T-145 → T-167 → T-189 → T-192 | |
| `C/session/WifiKnobs.kt` | T-197 only | T-183 no longer deletes it (audit K4). |
| `docs/PROTOCOL.md` (orchestrator prose) | 0018 prose (§3 step 3, §9) with T-150; T-152 (§3); T-163 (§4 KEY); T-171 (§6 one line); T-172 (§0x22, §6, §4 late-input bound); T-189 (§3.1); T-196 (§0x03); T-199 (§4, §7) | Batch into one or two orchestrator doc commits where timing allows. `gen.py --check` must stay green. |

---

## 3. Per-card details

Each card lists **files**, **acceptance** and **plan** hints. Everything else (goal, out-of-scope) is in the source report item named in §2.

### D1 — Safe baseline

**T-145 host-build-identity** (H BUILDID-H)
- **files:**
  - `scripts/bundle-host.sh`
  - `host-mac/Resources/Info.plist`
  - `HA/main.swift`
  - `HC/Session/BuildInfo.swift` *(new)*
  - `HT/Session/BuildInfoTests.swift` *(new)*
- **acceptance:**
  - [XCTest] `BuildInfo` parses an Info.plist dictionary; missing keys become `unknown`.
  - [device] `swift run` logs `sha=unknown` and does not crash.
  - [device] A bundled app logs `ev=app_start version= build=<CFBundleVersion> sha=<MBGitCommit> os=` once, and the menu shows the same SHA on a disabled "Sürüm …" line.
  - `check.sh` passes.
- **plan:**
  - `bundle-host.sh:64-67` already injects `CFBundleVersion` as a timestamp. Add `MBGitCommit` (short SHA, with `-dirty` when needed).
  - The first log line today is `listening` (SessionServer.swift:1068-1071). Log `app_start` before it.

**T-146 client-build-identity** (H BUILDID-C)
- **files:**
  - `client-android/app/build.gradle.kts`
  - `C/BuildInfo.kt` *(new)*
  - `C/MainActivity.kt` (one log call in `onCreate`)
  - `C/settings/SettingsCatalog.kt` (read-only "Sürüm" row)
  - `CT/BuildInfoTest.kt` *(new)*
- **acceptance:**
  - [JVM] `BuildInfo.logFields()` format; falls back to `sha=unknown` when git is unavailable.
  - `assembleDebug` works without `.git`.
  - [device] One `ev=app_start version= sha= built= sdk= os_build=` line per cold start; the panel shows the same SHA. No serial number and no device ID are logged.
- **plan:**
  - Add `buildFeatures { buildConfig = true }`.
  - Use `providers.exec { git rev-parse --short HEAD }` with `isIgnoreExitValue`.
  - Derive `versionCode` from the commit count. Today `versionCode=1` and `versionName="0.1"` (build.gradle.kts:15-16).

**T-147 recovery-runbook** (D P-7)
- **files:** `docs/RECOVERY.md` *(new, Turkish)*, `README.md` (link only), `docs/NOTES.md` (rehearsal results).
- **acceptance:** [device/user] each scenario is rehearsed once and recorded in NOTES with its date:
  - host quit or crash: relaunch without a screen via Parsec, SSH `open -a`, or Screen Sharing;
  - tablet app crash;
  - network loss → USB;
  - Screen Recording or Accessibility revoked (re-grant; Screen Recording needs an app restart, ScreenCapture.swift:15);
  - reboot with or without FileVault;
  - login and logout;
  - after a macOS update: a 5-minute smoke test (display at 2800×1840 @60 and @120 with `mode_selected=true`; Krita pressure, tilt and hover; pinch; Ctrl↔Cmd; one sleep/wake).
  - Also: last known-good pair recorded (macOS build, HarmonyOS build, host SHA, APK SHA, from T-145/T-146), and a recorded `./scripts/check.sh` pass on the Mac at that baseline commit. The review never ran it, so the test counts are not pass results (audit O3).
  - **Failure scenario first (M06 is an R-tagged finding):** each scenario is first performed and its actual outcome recorded (what the tablet shows, what the Mac log says), before any fix card is written.
  - The rollback screen is the **headless 1920×1080 placeholder** (`v0x756e6b6e/m0x76697274`, NOTES.md:160), not a physical monitor or HDMI dummy (audit K3). PLAN.md:9 is stale.
- **plan:**
  - Answers needed from the user (§5): FileVault, which remote path.
  - Parsec use is recorded in NOTES 2026-09-29 l.31 and 2026-09-30 l.253. The placeholder display is 1920×1080 (NOTES 2026-09-30 l.160).

**T-148 host-login-item-retry** (D P-6)
- **files:** `HA/LoginItem.swift`, `HC/Session/LoginItemPolicy.swift` *(new)*, `HT/Session/LoginItemPolicyTests.swift` *(new)*.
- **acceptance:**
  - [XCTest, first commit] A test reproduces today's bug (flag set before `register()`; a failed registration is never retried) and fails at HEAD.
  - [XCTest] first run + success → done; first run + failure → not done, retried next launch, problem shown; user toggled off → done, never auto-registered; not bundled → nothing persisted.
  - [device] Remove the login item, run `defaults delete dev.matebridge.host loginItemFirstRunDone`; the next launch registers it.
- **plan:** the bug is at LoginItem.swift:42-44: the flag is set before `register()`. Failure handling is at :60-64.

**T-149 ci-merge-gate** (H CI-1, H add. 1–2)
- **files:**
  - `.github/workflows/check.yml` *(new)*
  - `scripts/check.sh`
  - `protocol/fixtures/gen.py` (CLI only; orchestrator-owned)
  - `docs/WORKFLOW.md` (one line)
  - `docs/decisions/0022-ci-github-actions.md`
- **acceptance:**
  - `check.sh --only host|android|protocol`, defaulting to all (today's behaviour). It must not probe macOS paths when `JAVA_HOME`/`ANDROID_HOME` are set.
  - [CI] macOS runs `--only host` and `--only protocol`; Linux runs `--only android` and `--only protocol`.
  - [CI] A deliberately stale fixture fails the job.
  - [CI] Each job finishes in under 15 min with caches.
  - `gen.py` writes only with an explicit `--write` and fails on unknown arguments; `--check` is unchanged.
  - The decision states what is NOT covered.
- **plan:**
  - Today check.sh hard-codes macOS JBR and SDK paths (:24-26), runs CryptoKit vectors (:39-42) and builds probes (:16, :27). Probes stay excluded from CI.
  - `gen.py:460-476` regenerates on any invocation without `--check`.
  - Android needs AGP 9.4.1, Gradle 9.8.0, compileSdk 37, NDK 30.0.16248370 and CMake 4.1.2.
  - Run advisory for a week (timing-sensitive tests such as KeychainAsyncTests).

### D2 — Trust boundary

**T-150 client-pending-pair-trust** (A WI-1; A2 §1–2 and the A2 migration side finding; coordinator points a/b/c; coverage audit §3 A2(iii) and §4.7)
- **Before start:** the orchestrator merges decision 0018 and the PROTOCOL §3 step 3 / §9 prose.
- **files:**
  - `C/security/Handshake.kt`
  - `C/security/PairKeyStore.kt`
  - `C/session/SessionMachine.kt`
  - `C/session/SessionController.kt`
  - `C/session/SessionUi.kt`
  - `C/session/Settings.kt` (KeyValueStore `remove` / multi-key commit, if needed)
  - `CT/security/`, `CT/session/`
- **acceptance (all [JVM]):**
  - Stored key K for a host_id, then `KEY_PAIRING` ack, then a sealed `ACCEPTED`: K is unchanged and `inputAllowed == false`. No FILES_INFO, STREAM_PREFS, DISPLAY_RATE, AUDIO_PREFS or input is queued; only PING goes out. Inbound CLIPBOARD is not delivered.
  - The same with an unknown host_id: no trusted key is created and the session is not ACCEPTED.
  - **Token exposure (coordinator c):** a scripted fake host on the USB endpoint `127.0.0.1:47001` (squatter) or a discovered Wi-Fi endpoint completes PAIRING and sends ACCEPTED. It never receives FILES_INFO (the WebDAV token) without local confirmation. This closes the localhost-token path that broke decision 0015 item 3.
  - **User-initiated pairing (coordinator a):** a PAIRING ack on a connection opened by discovery, a saved endpoint, or the USB/AUTO probe (`userInitiated=false`) aborts before storing pending and yields `SessionUi.PairingNeedsUser(hostName, rePair)`. The same ack on `connect(…, userInitiated=true)` proceeds to the pending state.
  - Local confirm then host ACCEPTED, and the reverse order: pending is promoted (trusted = new key, pending removed); the session goes ACCEPTED with the existing action order. A STREAM_CONFIG that arrived before confirmation is buffered (latest only) and applied after it. (Risk: `onConfig` drops it when not ACCEPTED, SessionMachine.kt:340-341.)
  - Drop during approval, local confirm on return (pending still present), next connection PAIRED: completed with the promoted key (orphan flow, T-043/T-044).
  - Cancel, a local-confirm timeout (2 min) or REJECTED deletes pending; trusted is unchanged. A PAIRED handshake never uses unconfirmed pending.
  - A failed promotion → `KEY_STORE_FAILED`; nothing is half-written.
  - SAS, keys and tokens never appear in MbLog (grep test).
  - Old-contract tests are rewritten to assert "not replaced before confirmation": `CryptoVectorsTest.kt:233-245`, `SecureChannelTest.kt:113-119`.
  - Migration candidates still never store or pend.
  - **Migration gate (coordinator b; audit §4.7):** a T-096 AUTO-mode USB migration candidate that receives a plaintext PAIRED/ACCEPTED ack is NOT promoted until its first host record decrypts and authenticates. A bad first record aborts the candidate, and the live Wi-Fi session is untouched. A normal USB migration still promotes and gets no extra keyframe storm. Today promotion happens on the plaintext ack (SessionMachine.kt:463 → `promote` :492-511; SessionController.kt:677), and AutoUsbPolicy migrates every interval while ACCEPTED (AutoTransport.kt:193-201), so a localhost squatter that knows host_id can pull a live session (DoS).
  - `check.sh` passes.
  - Codex `--high`.
- **plan:**
  - Store: `pairpend.<hostId>` = wrap(key ‖ sas, aad = hostId ‖ "pending"). Add `getPending/putPending/promote/dropPending/remove`.
  - `storePairKey` → `storePending` at SessionController.kt:663-670 (same timing, but only when `userInitiated`).
  - Machine: add `hostAccepted` and `locallyTrusted` flags (or a phase `HOST_ACCEPTED_UNTRUSTED`). `inputAllowed` requires both. Add events `TrustConfirmed(gen)` and `TrustCancelled(gen)`. Keep PINGs running: the host heartbeat is 5 s, and the host tolerates the delay (SessionMachine.kt:358-368).
  - Gate inbound CLIPBOARD (SessionController.kt:367) and FILES_INFO (SessionMachine.kt:310) on `inputAllowed`.
  - Add `connect(ep, userInitiated: Boolean = false)`. Its callers change in T-151.
  - Size risk: if the migration gate does not fit in one context window, the implementer splits it into a follow-up card and records that under *Açık sorular*.

**T-151 client-trust-ui** (A WI-2; A2 §1)
- **files:**
  - `C/MainActivity.kt` (pairing screen; connect call sites for `userInitiated`; `onDiscovered`)
  - `C/session/SessionUi.kt`
  - `C/session/WakeConnect.kt`
  - `C/session/MacDiscovery.kt`
  - `C/session/AutoTransport.kt`
  - `C/settings/SettingsCatalog.kt`
  - `CR/values/strings.xml`
  - `CT/session/`, `CT/settings/`
- **acceptance:**
  - [JVM] UI-state mapping: `AwaitingApproval.needsLocalConfirm`. `PairingNeedsUser` shows the host name and an "Eşleş" action; tapping it calls `connect(ep, userInitiated=true)`.
  - [JVM] WakeConnect/AutoTransport: a discovered service, a saved endpoint, or the USB probe never starts pairing on its own. AutoTransport still treats a pending local confirm as `WAITING_USER` (AutoTransport.kt:245).
  - [JVM] "Bu Mac'i unut" removes the trusted key after a 2-step confirm.
  - The pairing screen has "Kodlar aynı — Güven" and "İptal".
  - A known host_id shows the warning "Bu Mac'in kimliği/anahtarı değişti. Kodu Mac'teki ile karşılaştırmadan onaylama".
  - On return, an unconfirmed pending record shows the stored code with the same buttons.
  - The Parsec hint text is updated.
  - [device] covered by T-157.
- **plan:**
  - `pairingText` is at MainActivity.kt:2053-2070, the `AwaitingApproval` render at :1897, and `onDiscovered` at :1803-1809.
  - `WakeConnect.kt:127-134` auto-connects to any resolved service, and `MacDiscovery.kt:105-122` resolves every `_matebridge._tcp` service. Keep auto-connect (PAIRED reconnect stays silent); only PAIRING needs the pick.
  - Risk: the Mac may flash its approval dialog when the tablet aborts. Accept this or note it.

**T-152 host-paired-proof-first** (A WI-3; A2 §3)
- **Before or at merge:** the orchestrator applies PROTOCOL §3 step 3 prose: "host her PAIRED bağlantıda ilk doğrulanmış kaydı bekler, sonra etkinleştirir ve STREAM_CONFIG gönderir".
- **files:** `HC/Session/SessionMachine.swift`, `HT/Session/`.
- **acceptance:**
  - [XCTest] Non-takeover PAIRED with no record: no `.sessionStarted` and no `.send(streamConfig)`; closed at `proofTimeoutUs`.
  - [XCTest] PAIRED + a valid PING: `.sessionStarted`, then STREAM_CONFIG, then a pong.
  - [XCTest] Proving connections count toward `maxUnauthenticated` (=4).
  - [XCTest] Existing takeover tests pass unchanged.
  - [device] A normal reconnect still shows video (about +1 RTT).
  - Codex.
- **plan:**
  - The `continueHello` PAIRED branch is at SessionMachine.swift:646-668; `start()` at :726-735. Route both cases through `.proving`; `prove()` must handle "no slot owner".
  - The client sends the proof PING first (client SessionMachine.kt:305).
  - Side effects that disappear: StreamCoordinator.swift:307-328 (sleep gate, `displaySleep.hold`, `lease.sessionStarted` → display create).

**T-153 client-files-session-lifetime** (A WI-6 lifetime part; A A4)
- **files:** `C/files/FilesController.kt`, `C/files/FilesSwitch.kt`, `C/MainActivity.kt` (one call site: session-accepted and transport signal), `CT/files/`.
- **acceptance:**
  - [JVM] `FilesSwitch.shouldRun` requires: foreground, setting on, permission granted, session ACCEPTED **and locally trusted** (T-150), and `transport == USB`.
  - [JVM] A session end or a switch to Wi-Fi stops the server and invalidates the token.
  - [device] Unplugging USB → `state=off`; replugging → a new token and the Finder mount works.
- **plan:** today the server runs whenever the activity is in the foreground and sharing is on (FilesController.kt:39-47). The token is created per start (:79-80).

**T-154 client-data-extraction-rules** (A A5; A2 §4)
- **files:** `client-android/app/src/main/AndroidManifest.xml`, `CR/xml/data_extraction_rules.xml` *(new; the `res/xml/` directory is new)*.
- **acceptance:**
  - `android:dataExtractionRules` excludes all shared_prefs (`matebridge`, `matebridge_pairkeys`, `matebridge_audio`) from `<cloud-backup>` and `<device-transfer>`. `allowBackup="false"` is kept.
  - `assembleDebug` passes, and `aapt2 dump xmltree` shows the attribute.
  - [device] not verifiable (HarmonyOS Phone Clone); state "not run".
- **plan:** targetSdk 31 (build.gradle.kts:14) and AndroidManifest.xml:16-17. This is Low; it is batched at D2 per the coordinator.

**T-155 host-orphan-approval-guard** (A A6, A §M05 correction 3)
- **files:** `HC/Session/SessionMachine.swift`, `HA/ApprovalPanel.swift`, `HT/Session/`.
- **acceptance:**
  - [XCTest] A new PAIRING request from a different device_id while an orphan window is open does not silently replace it. The panel event carries `replacedPrevious=true`, and the panel shows "Bu, önceki istekten FARKLI bir cihaz" plus a short device fingerprint.
  - [device] Two-tablet or scripted HELLO test.
  - Codex.
- **plan:** replacement happens at SessionMachine.swift:683-687; the panel is ApprovalPanel.swift:12-26. Do not block the new request (that would be a DoS); make it visible. The user decides whether to keep the orphan flow at all (§5 Q3).

**T-156 client-key-mismatch-state** (A WI-7)
- **files:** `C/session/SessionMachine.kt`, `C/session/SessionController.kt`, `C/session/SessionUi.kt`, `CR/values/strings.xml`, `CT/session/`.
- **acceptance:**
  - [JVM] 3 consecutive record-auth failures on PAIRED connections → `Failed(KEY_MISMATCH)`, with text pointing to "Bu Mac'i unut" / "Onaylı cihazları unut".
  - [JVM] A single failure still retries.
- **plan:** today this goes `lose(PROTOCOL_ERROR)` at SessionMachine.kt:211-215.

**T-157 trust-device-acceptance** (A WI-4)
- **files:** `docs/NOTES.md`.
- **acceptance:** [device] each step is logged in NOTES with its log events, and no key, SAS or token appears in any log:
  1. Paired baseline: the reconnect is silent PAIRED.
  2. Mac "Onaylı cihazları unut" (same host_id PAIRING): the tablet shows "Eşleş" (not auto). Then "İptal": the key is kept and nothing is injected. Then Mac "İzin ver" without a tablet confirm: nothing is injected.
  3. Real re-pair, confirmed on both sides.
  4. Orphan/Parsec flow.
  5. New host (second instance or another user): never ACCEPTED without pick + confirm.
  6. Debug-only localhost squatter on 47001 with reverse removed: no FILES_INFO, no input.
  7. AUTO-mode USB↔Wi-Fi migration still works (T-150 migration gate).
  8. T-152: reconnect still shows video.

### D3 — Video health and input safety

**T-158 client-decoder-backend-seam** (H TESTSEAM-1 client, named per B P3; prerequisite of T-159 fault injection and T-161 tests; audit §4.3)
- **files:** `C/video/VideoRenderer.kt`, `C/video/DecoderCodec.kt` *(new: interface plus MediaCodec adapter)*, `CT/video/FakeDecoderCodec.kt` *(new)*, `CT/video/`.
- **acceptance:**
  - [JVM] The fake drives `runCodec`/`decodeAttempts` and reproduces today's behaviour (give-up after 3 restarts in 10 s; `previous.join` ordering). This documents the as-is H02/M03 behaviour.
  - No behaviour change.
  - [device] Smoke: connect, 10 mode changes, no regression.
- **plan:**
  - MediaCodec calls are at VideoRenderer.kt:276-305 (create/configure) and :454-472 (queue).
  - Keep the interface minimal: create/configure/start/dequeueIn/queueIn/dequeueOut/releaseOut/stop/release.
  - The `codec.configure(format, surface…)` surface argument stays an opaque handle.

**T-159 client-video-health-gate** (B P1; decision 0019)
- **files:**
  - `C/video/VideoHealth.kt` *(new, pure)*
  - `C/video/VideoRenderer.kt`
  - `C/MainActivity.kt`
  - `C/session/SessionMachine.kt` (frames reset on reconnect only)
  - `CR/values/strings.xml`
  - `CT/video/VideoHealthTest.kt` *(new)*
- **acceptance:**
  - [JVM] Transitions:
    - STARTING → HEALTHY on the first output;
    - HEALTHY → FAULT on give-up, on no output while fed (1500 ms and ≥3 inputs), or when the decoder is not running while attached;
    - a static screen stays HEALTHY;
    - recovery steps are bounded and ordered;
    - a new generation is STARTING until its first output.
  - [JVM] FAULT stops keyframe retries and feeding (fake clock), which stops the ~2 IDR/s loop (B add. 1).
  - `syncInputActive` includes `videoHealth.inputAllowed`. FAULT → `capture.setActive(false)` → the existing releases + `RELEASE_ALL(USER)`.
  - [JVM] After an automatic reconnect or migration, input stays closed until the first decoded output of the new generation (B add. 2; `SM:175/317` frame counter).
  - The overlay text and a "Yeniden dene" button appear on FAULT (B add. 5).
  - `ev=video_health state= cause=` is logged per LOGGING.md.
  - Debug-only `--es decoder_fault create|configure|dequeue|silent` drives the fake through the `DecoderCodec` seam (T-158).
  - [device] Runs in T-164.
  - Codex (input-state change).
- **plan:**
  - Hooks: VideoRenderer.kt:347-351 (give-up), `drainOutput` :540-548 (first output, last output time), :472 (inputs queued), MainActivity.kt:643-649 (gate), :1154 (`onGiveUp` only logs today), :1884 (`streaming` uses received frames).
  - The 500 ms ticker at MainActivity.kt:1365-1379 evaluates the timer.
  - Base timing on decoder output, not on `onFrameRendered`.

**T-160 client-video-delivery-gate** (B P2; B add. 4)
- **files:**
  - `C/session/SessionController.kt`
  - `C/session/VideoDeliveryGate.kt` *(new, pure)*
  - `C/video/VideoRenderer.kt` (installed-config token)
  - `C/MainActivity.kt` (`onVideoFrame`, `installConfig`)
  - `CT/session/VideoDeliveryGateTest.kt` *(new)*
- **acceptance:**
  - **[JVM, first commit, red at HEAD]** M01 is an R-tagged finding, so the card starts with a deterministic failing scenario: the barrier test below, written against the extracted gate with today's configId-only rule, must deliver a stale frame. Only then implement the fix.
  - [JVM, deterministic, X4] A reader is blocked at a barrier before delivery; then `abort()` and a new gen/config are activated; then the reader is released → it delivers zero frames. The same holds for buffered complete records after `abort()`.
  - [JVM] A frame whose configId ≠ the renderer-installed configId is dropped. Installing K after K-frames were dropped → exactly one STARTUP request and no FRAMES_DROPPED storm.
  - [JVM] Same configId 1 in consecutive sessions → frames from session N are dropped once N+1 is current.
  - `currentConfigId` is reset to -1 on CloseVideo/CloseControl.
  - [device] 10× USB↔Wi-Fi migration + 10× mode change under motion: each recovers on its first keyframe, there is no `decode_error`, and `kf_req` per switch is ≤ 2.
- **plan:**
  - Today: SessionController.kt:837-844 checks only configId. The host configID always starts at 1 (StreamCoordinator.swift:14, :202). `abort()` is at :803-806.
  - The gate holds `(videoGen, installedConfigId)` under a lock, and `deliver` runs inside it (`offer` does not block).
  - `installedConfigId` is set after `r.reconfigure` (MainActivity.kt:1177).
  - Mirror the audio pre-filter at SessionController.kt:749.

**T-161 client-decoder-teardown-bounds** (B P3; B add. 3)
- **files:**
  - `C/video/VideoRenderer.kt`
  - `C/video/RestartPolicy.kt`
  - `C/video/CodecGeneration.kt` *(new, optional)*
  - `CT/video/`
- **acceptance:**
  - **[JVM, first commit, red at HEAD]** M03 is an R-tagged finding: with the T-158 fake codec, a previous generation that never exits makes the next attach wait forever, and a straggler output thread mutates the next generation's gauge. Both are written as failing tests before the fix.
  - `previous.join(2000)` → on timeout, log `ev=decoder_previous_stuck`, report FAULT(stuck) and do not open a codec. Keep only a single "last stuck" reference, so the chain does not grow.
  - A generation counts as finished only when both the input and output threads have exited. A straggler output thread is recorded and included in the next wait.
  - `lastOutputNs`, `formatChanged`, the gauge, pacer references and PTS maps become per-generation. Shared `stats`/`counters` are updated only by the current generation.
  - `decodeAttempts` uses backoff: 100 ms / 500 ms / 1 s.
  - [JVM, fake codec from T-158] A hung previous generation → bounded wait, FAULT, no new codec. A straggler does not change the next generation's gauge or `firstOutput`.
  - [device] Runs in T-164.
- **plan:**
  - Locations: VideoRenderer.kt:263-272 (retire), :328 (unbounded join), :357-491 (`runCodec`), :482-489 (finally), :493-495 (shared fields), :343-344 (immediate restart).
  - The UI-thread `detachSurface` join (300 ms) must stay bounded.

**T-162 host-encoder-submit-owner** (C M02-H + additional issues 1–6; H TESTSEAM-1 host as an explicit first step)
- **files:**
  - `HH/Video/HEVCEncoder.swift`
  - `HC/Video/EncoderSubmitOrder.swift` *(new: pure ordering/lifecycle plus `CompressionBackend` protocol)*
  - `HT/Video/EncoderSubmitOrderTests.swift` *(new)*
  - `HH/Video/VideoPipeline.swift` (only if teardown must await the owner queue)
- **Step 1 (separate commit, no behaviour change):** move the reserve/take-pending/stopped decision into Core behind `CompressionBackend`. A test with a fake backend documents today's ordering. The `MateBridgeHost` target has no test target (Package.swift:18), so this seam is the prerequisite.
- **acceptance:**
  - **[XCTest, step 1, red at HEAD]** M02 is an R-tagged finding: against the extracted step-1 logic (today's ordering), the barrier test below shows a submit after invalidate and a PTS inversion. Only then change the ordering.
  - [XCTest] A barrier between reserve and submit plus a concurrent `stop()` → zero `encode` calls after `invalidate`. Deterministic, with no sleeps.
  - [XCTest] A 10 000-iteration stress (capture offers, `bypassGate` resubmits, flush-timer takes, slot releases, stop) → strictly increasing backend PTS, one release per reservation, and `0 ≤ inFlight ≤ maxInFlight`.
  - [XCTest] Mutation check: a broken variant (submit after unlock on the caller thread) fails the first test. Record this in Handoff.
  - The `inFlight` release is idempotent per reservation token; a double release logs `warning`.
  - `updateQPBoost` moves into the same submit block.
  - CMBlockBuffer: if `lengthAtOffset != totalLength`, use `CMBlockBufferCopyDataBytes` (HEVCEncoder.swift:705-711).
  - Teardown `CompleteFrames`/`Invalidate` runs on the owner queue (C add. 5).
  - [device] 10 min at 120 fps with 20 STREAM_PREFS changes and 10 video reconnects → `ev=encode_failed` = 0. `enc` and `cap_to_sent` p50 within ±0.3 ms of the baseline; p99 not grown.
  - Codex optional (`--medium`).
- **plan:**
  - Reservation is at :495-516, :624-634 and :536-548; `send` at :565; stop at :659-679; QP at :431-453; the thread map is in C.
  - Shape: under `lock`, after `reserveSlot`, call `submitQueue.async { send }`. Stop sets `stopped` under the lock, then `submitQueue.async { Complete; Invalidate }`.
  - Never `submitQueue.sync` from a VT callback or `deinit`; use `setSpecific`.

**T-163 host-key-repeat-stall-pause** (G P-KR; amends 0003)
- **Prose:** the orchestrator adds a 4th KEY host stop condition to PROTOCOL §4 and a note to decision 0003.
- **files:**
  - `HC/Input/InputStateMachine+Keyboard.swift`
  - `HC/Input/InputStateMachine.swift`
  - `HC/Input/InputPipeline.swift`
  - `HH/Input/InputController.swift`
  - `HH/Session/SessionServer.swift` (a `noteControlActivity` hook only)
  - `HT/Input/`
- **acceptance:**
  - [XCTest, fake clock] No repeat is emitted while `now − lastControlActivity > 600 ms`. Repeat resumes after activity if the key is still held. UP and release-all still stop it. No burst after resume.
  - [device] Hold a key on Wi-Fi and toggle tablet Wi-Fi: at most ~1 extra repeat and no stuck key.
  - Codex (input state).
- **plan:**
  - Repeat is armed and stopped at InputStateMachine+Keyboard.swift:83-85, 99-110.
  - Update the activity timestamp for every decoded control record (PING included) on the session queue. Pass it without `queue.sync` re-entry (an atomic).

**T-164 video-fault-churn-device-run** (B P4; H add. 6)
- **files:** `docs/NOTES.md`.
- **acceptance:** [device], with results dated in NOTES and any skipped run marked "not run":
  - For each `decoder_fault` mode, 5 runs: time from fault to `input_active on=0`; host owed-release count = 0 while Shift is held and the pen is down; time to the first image after recovery.
  - 100× fg/bg + 100× mode change + surface churn (GL↔surface fallback churn only if T-184 has not yet removed the GL path): thread count (`/proc/<pid>/task`), `dumpsys media.codec` instances and RSS return to baseline ±5 %.
  - Report the `detach_slow`, `decoder_previous_stuck`, `audio_previous_slow` and `api=` fallback counts.

### D4 — Display decoupling

**T-165 host-park-virtual-display** (D P-2)
- **files:**
  - `HC/Video/DisplayLease.swift`
  - `HH/Session/StreamCoordinator.swift`
  - `HH/Video/VideoPipeline.swift`
  - `HT/Video/DisplayLeaseTests.swift` *(new, or extend the DisplayLease tests in `HT/Video/IntegrationTests.swift`)*
  - `docs/LOGGING.md`
- **acceptance:**
  - [XCTest] `sessionEnded` → `.park`. `tick` past the deadline → `.teardown` exactly once. Same device + `sameDisplay` → create reusing the parked display. Refresh mismatch → recreate. Different device or size → teardown + create. Shutdown while parked → teardown. `displayLost` while parked → idle. The 10 s default semantics are kept.
  - [XCTest] A pure parse of `MATEBRIDGE_DISPLAY_KEEP_S` (10…86400, otherwise 10).
  - Log `display_parked keep_s=`, `display_unparked`, `display_teardown reason=keep_expired|device_changed|size_changed|shutdown`.
  - [device] Parked → CPU and GPU at idle. Reconnect within the window shows an image within 1 s, **also on a static screen, 5/5** (T-028 guard). A Smooth→Clarity change while parked recreates once.
- **plan:**
  - `onSessionEnded` calls `pipeline.stopKeepingDisplay()` (VideoPipeline.swift:248-253) instead of `startDrain()` (StreamCoordinator.swift:403-405, 719-724). Then `createPipeline(reusing: parked)`.
  - `restartPipeline` (:564-574) is the device-tested precedent (T-049).
  - If `CGDisplayIsOnline(parked)` is false, create a new display.
  - VirtualDisplay stays the only private-API file (`HH/VirtualDisplay.swift`).
  - Use a continuous clock if the keep time is meant as wall time (D add. 5; HostClock is mach absolute time).
  - Low-severity notes for later, not fixed here: D add. 3 (`Thread.sleep` in async, VirtualDisplay.swift:134-146) and add. 4 (no fallback in the recreate path).

**T-166 parked-display-measurement** (D P-3; D add. 2, 6)
- **files:** `docs/NOTES.md`.
- **procedure:** [device/user] start the host with `MATEBRIDGE_DISPLAY_KEEP_S=3600`, with Krita and 2 windows arranged.
  1. Screen off 30 s, then 5 min: window and panel positions, time to first image.
  2. `pmset displaysleepnow` while parked: `CGDisplayIsOnline` for `v0x4d42/m0x1` during and after, and placement after reconnect. This covers D add. 6 (no display-sleep assertion while parked).
  3. `pmset sleepnow`: grep `display_reused|display_created|display_create_failed`. This settles D add. 2 (T-132's reuse assumption).
  4. Parsec while parked: can it see and control the display?
  5. Idle CPU, GPU and RSS for 5 min.
- **acceptance:** a NOTES entry; the user picks the 0020 default; T-200 go/no-go is recorded.

**T-167 host-display-keep-menu** (D P-4; 0020 accepted)
- **files:**
  - `HA/main.swift`
  - `HH/Session/StreamCoordinator.swift`
  - `HC/Video/DisplayLease.swift` (keep-duration setter)
  - `HC/Video/DisplayKeepPolicy.swift` *(new)*
  - `HT/Video/DisplayKeepPolicyTests.swift` *(new)*
- **acceptance:**
  - [XCTest] Preference parse, default and round-trip. A keep change while parked takes effect from now.
  - "Remove now" while a session is live is either disabled or ends the session first; choose and justify in Plan.
  - Status line "Sanal ekran bekletiliyor (mm:ss)".
  - [device] Remove while parked → windows go back to the placeholder; `display_teardown reason=user`.
- **plan:** the menu action is a new coordinator mailbox event (lifecycle, forced). Never touch `VirtualDisplay` from the app. The env knob from T-165 still wins.

### D5 — Measurement

**T-168 client-latency-stage-stats** (E W1; E add. 1, 4, 6)
- **files:**
  - `C/video/VideoStats.kt`
  - `C/video/VideoRenderer.kt`
  - `C/video/IntervalHistogram.kt`
  - `C/stream/ClockSync.kt`
  - `C/stream/StatsFormat.kt`
  - `C/MainActivity.kt` (`statsTick`, `writeStatsLog`, `latencyOf` only)
  - `CT/video/`, `CT/stream/`
  - `docs/LOGGING.md` (client video stats section)
- **acceptance:**
  - [JVM] New `MB/render ev=stats` fields:
    - `cap_dec_p50/p95/p99/max_us` (with `latency_us` kept as an alias for one release);
    - `ready_slot_p50/p95/p99_us`;
    - `cap_rel_*`;
    - `cap_cb_*` (codec-render mode);
    - `render_cb_missing`;
    - `lat_neg`;
    - `clock_unc_us` (= best RTT / 2).
  - Raw latency is signed; the clamp applies only where a u32 is written (`ClockSync.kt:31`).
  - Only released frames count toward `cap_rel`/`cap_cb`; discarded frames are counted separately.
  - The overlay "Gecikme" becomes "Yak→çöz", and a line shows `ready→slot p50` and `±clock`.
  - [JVM] VideoStats maps are cleared on stream and codec boundaries. 70 stale high keys followed by a new stream at seq 0 still yields samples (VideoStats.kt:64-65, 116-121).
  - `shown=` → `released=` (with an alias).
  - **PF7 (client decoder hardware check; audit §3 PF7):** `ev=codec_start` gains `is_hw=` / `sw_only=` (`MediaCodecInfo.isHardwareAccelerated` / `isSoftwareOnly`, API 29+), and a software decoder logs one warning line (mirrors T-187). Today `createDecoderByType` (VideoRenderer.kt:294) takes the platform default and only `name=` is logged (:322-323).
  - [device] On USB at 120 Hz while drawing: `ready_slot_p50` ≈ 13–17 ms, `lat_neg` = 0.
  - The STATS wire layout is unchanged.
- **plan:**
  - `drainOutput` (VideoRenderer.kt:546-573) has `readyNs` and `d.slotNs`.
  - `CodecSink.release` (:499) needs a pts → captureUs lookup (`captureByPts`).
  - VideoStats methods stay `@Synchronized` (the render callback runs on the main looper).
  - Does not correct the 6.6 ms lead (that is 0021).

**T-169 client-refresh-target-log** (E W7)
- **files:** `C/MainActivity.kt` (stats line + `applyRefreshRate` logging only), `CT/stream/`, `docs/LOGGING.md`.
- **acceptance:**
  - [JVM] The line carries `target_hz=` (`FrameRatePolicy.modeTargetHz`), `display_hz=`, `vsync_ms_p50=` and `stream_mode=`. The duplicate `hz=` becomes an alias.
  - [JVM] A rate-limited `ev=refresh_mismatch` when the target ≠ measured Hz for more than 5 s while streaming.
- **plan:** `hz=` and `display_hz=` are duplicates today (MainActivity.kt:1467-1468).

**T-170 host-latency-trace-join** (E W2; E add. 2)
- **files:**
  - `HC/Video/LatencyTrace.swift`
  - `HH/Video/LatencyCsv.swift`
  - `HH/Video/HEVCEncoder.swift` (trace fields only)
  - `HC/Video/VideoSender.swift` (record seq into the trace)
  - `HC/Video/StatsSummary.swift`
  - `HT/Video/`
  - `docs/LOGGING.md`
- **acceptance:**
  - [XCTest] `latency.csv` appends `pts_us` (the exact wire `capture_time_us`), `display_us`, `frame_seq`, `config_id`, `session_id` and `resubmit`, with the existing column order kept.
  - `ev=latency` adds a signed PTS-origin `cap_to_sent` and logs a `pts_vs_deliv` p50/p1/p99 summary (the input for 0021).
  - The StatsSummary comment and menu text read "tablet capture→decode"; `latency_ms` → `cap_dec_ms` (with an alias).
  - [device] A 60 s USB run with `MATEBRIDGE_LAT_TRACE=1` plus the client `pace_trace` joins on ≥99 % of frames.
- **plan:** `FrameTrace.origin` (LatencyTrace.swift:64-69) and the header at :83-88. `frame_seq` is assigned at VideoSender.swift:99.

**T-171 host-input-age-ping** (E W3 + G P-M04b, merged into one card. No decision record: PROTOCOL.md:567 already says "Host da aynı aralıkla gönderebilir", and there is no wire or dependency change. At most a one-line §6 clarification by the orchestrator.)
- **files:**
  - `HC/Session/SessionMachine.swift`
  - `HC/Input/InputAge.swift` *(new: offset estimator + age histogram)*
  - `HH/Session/SessionServer.swift`
  - `HH/Input/InputController.swift`
  - `HT/Session/`, `HT/Input/`
  - `docs/LOGGING.md`
- **acceptance:**
  - [XCTest] The offset estimator picks the min-RTT sample and survives skew or backwards jumps.
  - [XCTest] Age per PEN sample = `hostRecv − (base + dt − offset)`; the same for KEY/POINTER/SCROLL/PINCH `time_us`. Negatives are kept and reported, not clamped.
  - [XCTest] PING every 500 ms only on an ACCEPTED **and activated** connection (after T-152's `.proving` step), never during proving. A PONG with an unknown seq or from another connection is ignored. No PING is sent before ACCEPTED.
  - One log shape (G's): `ev=input_age` once per second while input flows, with p50/p95/p99/max per class (pen/pointer/key/scroll), `late_250ms`, `offset_rtt_us`/`clock_unc_us`; session totals in `input_session_end`. No keys, characters or coordinates.
  - [device] USB p50 is a few ms; Wi-Fi numbers are recorded in NOTES.
  - Codex (input path).
- **plan:**
  - The host ignores PONG today (SessionMachine.swift:741-756); the client already answers PING (client SessionMachine.kt:280).
  - Client clocks: CLOCK_MONOTONIC on both sides (`eventTime*1000` and `nanoTime/1000`), with 1 ms resolution.
  - Compute on the input queue, into a fixed histogram.

**T-172 latency-semantics-docs** (C LM4-D, E W4, E add. 3, G add. 2; decision 0021)
- **files:** `docs/decisions/0021-capture-timestamp-semantics.md`, `docs/PROTOCOL.md`, `docs/LOGGING.md`; `protocol/fixtures/` only if option B.
- **acceptance:**
  - The decision is recorded with the T-170 `pts_vs_deliv` data.
  - The PROTOCOL §0x22 `latency_avg_us` and §6 formula say "decoder output", not "ekranda gösterim".
  - PROTOCOL §4 "Kabul edilen davranış" states that the real late-input bound is the host's 5 s silence close, not the 1 s client queue.
  - LOGGING notes that `latency_us` excludes the SCK lead, and that macOS `unacked_bytes` is an `sbbytes` estimate (F A-5).
  - `gen.py --check` is green.
  - **If option B:** the orchestrator writes a new fixture `video_frame_origin`, and two follow-up cards (host + client) are created. Wire.

**T-173 measurement-kit-smoke** (E W6 + H SOAK-1 tooling, merged into one card; audit §4.3)
- **files:**
  - `tools/measure/` *(new: `mbmon.sh`, `an.py`, `macmon.sh`, `macan.py`, README)*
  - `tools/soak/` *(new: tablet/host samplers, `summarize.py`)*
  - `scripts/device-smoke.sh` *(new)*
  - `docs/WORKFLOW.md` (one paragraph)
- **acceptance:**
  - `device-smoke.sh` prints the host/APK SHA (T-145/T-146), host OS, tablet `ro.build.display.id`, codec name, `stream_config`, panel Hz + `vsync_ms_p50`, and the transport. It collects 60 s of numeric-only stats and prints p50/p95. No clipboard, key or text lines.
  - The soak samplers record, every 60 s:
    - host RSS, `lsof` count and threads;
    - tablet PSS, `/proc/<pid>/fd`, threads grouped by prefix, and `dumpsys media.codec`/`resource_manager` instances;
    - log-event counts (`decoder_give_up`, `detach_slow`, `audio_previous_slow`, `pipeline_retry`, `release_all`, reconnects).
  - Result headers name the commit, OS versions, codec, topology, resolution, target and real Hz, bitrate, content, duration and run count (≥3).
  - bash and python3 stdlib only (no decision needed).
- **plan:** the recipes are in NOTES (~l.1060, 1069, 1117). The scratch tools were lost. `tools/pacing/` is the precedent.

**T-174 optical-latency-baseline** (E W5)
- **files:** `docs/NOTES.md`, `tools/measure/optical/README.md` *(new)*.
- **procedure:** [user]
  1. 240 fps phone camera; Krita smoothing "Yok".
  2. USB 120 Hz pen: 30 taps.
  3. USB 60 Hz with the **keyboard** (the pen forces 120 Hz, per PF3).
  4. Wi-Fi: the same.
  5. ≥3 days per condition; report p50/p95/max and the count of >100 ms. Keep T-168/T-171 logs from the same minute.
  6. Residual = optical − (`cap_cb` + 6.6 ms + `input_age`).
- **acceptance:** a NOTES table; a draft budgets decision (B1; unnumbered until drafted); no raw video committed.

**T-175 host-input-delivery-timing** (F F-6 + G P-L03i, merged into one card; L03 is R-tagged, so measurement comes first and optimisation is a follow-up)
- **files:**
  - `HH/Input/InputController.swift`
  - `HH/Input/CGEventPoster.swift` (timing only)
  - `HH/Input/VirtualDisplayLocator.swift` (timing only)
  - `HC/Input/` (pure aggregate helper)
  - `HT/Input/`
  - `docs/LOGGING.md`
- **acceptance:**
  - [XCTest] The aggregate helper.
  - `input_session_end` gains `deliver_us_avg/p99/max`, `env_us_avg/max`, `post_us_avg/max`, plus a rate-limited warning when one call exceeds 20 ms. No coordinates or keys.
  - [device] 10 min mixed use plus a mode switch, recorded in NOTES.
  - Optimisation only as a follow-up, and only if >50 µs/message or p99 deliver exceeds a few ms. Options: cache geometry on `CGDisplayRegisterReconfigurationCallback`; reuse `CGEventSource`, which needs a Krita check.
- **plan:** `deliver` at InputController.swift:177-200, environment at :320-338, post at :283-308. The timing pattern is `liveCursor` at :251-260. VirtualDisplayLocator.swift:33-44, 67-88 queries CG on every message.

### D6 — Wi-Fi

**T-127 (re-scope) wifi-video-burst-pacing** (F "T-127 re-scoped")
- **Frontmatter changes:** `phase: 5 → 6`; `depends_on: [T-126, T-168, T-170, T-173]`; `files:` adds `docs/NOTES.md`. Keep the existing diagnosis text.
- **Step mapping:**
  - old steps 1–2 become matrix rows;
  - old step 3 is superseded by T-178/T-195/T-196 (via 0023);
  - old step 4 stays as the documented last resort.
- **acceptance:** [device/user]
  - Write the budgets down BEFORE the runs: audio underruns ≤1 per 5 min; control srtt p95 ≤40 ms; client capture→decode p95 ≤70 ms on Wi-Fi.
  - Same scripted workload (full-screen pan/scroll, Krita pinch, app switch, music, 5 min) over USB, Mac Ethernet + tablet Wi-Fi, and both on Wi-Fi. ≥3 runs each. Record:
    - host `ev=tcp` control/video srtt p50/p95/max, sbbytes p95/max, retx;
    - `ev=sendq` (`MATEBRIDGE_SENDQ_LOG=1`);
    - `idr=`/`idr_bytes_max=` per second (F A-1 check);
    - client underruns/owd, T-168 latency percentiles, fps.
  - Topology 3 at the default bitrate, 30 and 15 Mbps.
  - Topology 3 with `--ei tos_ctl 0xB8 --ez wifi_ll true`. The 2026-10-01 result was confounded by `nw` (audit K4). The knobs stay until this row reports; then the orchestrator records keep or retire in `docs/KNOBS.md`.
  - Note the AWDL state and channel/width/DFS.
  - Record the result and the 0023 branch choice ("fixed profile suffices" / "go adaptive") in NOTES.
- **plan:** measure Ethernet first. Read `unacked_bytes` as `sbbytes` (F A-5). Optionally run T-179 in the same session. LM7 note: the delay is AP/driver queueing behind bursts, not serialisation at the encoder rate. The raw link is ~410 Mbit/s per flow (NOTES.md:603-610); 60 Mbps is the stream bitrate, not link capacity (audit K2, F is right).

**T-176 host-drop-idr-feedback** (F F-4; F A-1, A-2)
- **files:**
  - `HC/Video/BoundedFrameQueue.swift`
  - `HC/Video/VideoFrameQueue.swift`
  - `HC/Video/KeyframeRequestCoalescer.swift`
  - `HH/Video/VideoPipeline.swift`
  - `HH/Video/HEVCEncoder.swift` (encode-skip hook only)
  - `HT/Video/`
- **acceptance:**
  - [XCTest] `[IDR, d1] + d2` no longer yields `keyframeNeeded` when a queued IDR exists ahead of the dropped delta. The stream stays decodable; document which policy was chosen, with the reference-chain argument.
  - [XCTest] `internalForce` is coalesced within `windowUs`, with a pending timeout so nothing is swallowed forever.
  - Optional (b): skip submits while the sender is blocked for more than one frame interval.
  - [device] `idr=` per second during Wi-Fi bursts is below the T-127 baseline, with no rise in `frames_dropped` or decode errors.
  - Codex (keyframe/reference-chain logic).
- **plan:** the forward-only keyframe scan is at BoundedFrameQueue.swift:40-64; the unconditional force at VideoPipeline.swift:182-188; `requestKeyframe(resubmitNow:)` at HEVCEncoder.swift:307-310. This can land before T-127's measurements, since it fixes a reasoned loop, and T-127's `idr=` data verifies it.

**T-177 host-live-bitrate-setter** (F F-1; F A-3)
- **files:**
  - `HH/Video/HEVCEncoder.swift`
  - `HH/Video/VideoPipeline.swift`
  - `HC/Video/EncoderKnobs.swift` (debug step knob)
  - `HC/Video/EncoderSubmitOrder.swift` (route through the owner queue from T-162)
  - `HT/Video/`
  - `docs/LOGGING.md`
- **acceptance:**
  - [XCTest] The rate-request value type: clamp to [floor, ceiling]; deduplicate equal values. The setter is serialised with submit/invalidate (no call after stop; via the T-162 owner).
  - Log `video ev=bitrate_set kbps= status=`.
  - [device] Step knob 60→15→60 Mbps on a scrolling page: per-second bytes follow within ≤1 s, with no video reconnect and no `STREAM_CONFIG`. Record the VT status codes.
  - Also try a short-window `DataRateLimits` pair (100 ms) and report whether it is accepted (F A-3).
- **plan:** the precedent is the live `MaxAllowedFrameQP` at HEVCEncoder.swift:430-452; creation-time rates at :168-184. `Quality` mode may ignore the setter; measure it.

**T-178 host-wifi-default-bitrate** (F F-7 host-only; 0023 branch (b); **gated on T-127**)
- **files:** `HC/Video/TransportBitrate.swift`, `HC/Video/StreamPrefsPolicy.swift`, `HT/Video/`.
- **acceptance:**
  - [XCTest] On `transport=wifi`, the mode default uses the Wi-Fi value chosen from T-127. User STREAM_PREFS and env priority are unchanged (0013).
  - [device] Re-run the T-127 topology-3 row; record in NOTES.
- **plan:** `applyingTransportKnobs` already knows the transport at session start. Defaults are at StreamPrefsPolicy.swift:21-27. Wire: none, because the host-only variant was chosen. A `STREAM_PREFS` Wi-Fi field would be wire and is rejected in 0023.

### D7 — Pen

**T-179 pen-wifi-rhythm-measurement** (G P-M04a; G add. 5)
- **files:** `docs/NOTES.md`.
- **acceptance:** [device] same 6-fast-circle workload over the 3 topologies, ≥3 runs each:
  - inter-event median, p95, max and the 0–1 ms share at the Mac. Use a scratch AppKit receiver with `NSEvent.isMouseCoalescingEnabled = false` set after launch (NOTES l.179);
  - client `pen_msgs`/`pen_samples`/`max_batch`, host `input_session_end`, and T-171 `input_age`;
  - the user's Krita verdict with smoothing = None.
- **plan:** pre-T-111 numbers are in NOTES l.169-178. The T-111 handoff check was never recorded.

**T-180 pen-keyboard-validation-matrix** (G P-PK)
- **files:** `docs/NOTES.md`; `scripts/` only if a recorder tool is versioned.
- **acceptance:** [device], each failure becomes its own card:
  - tilt 4 directions × 2 landscape rotations (`sensorLandscape`): the Krita Tablet Tester sign matches the physical lean;
  - corners + centre: error < 1 pt, letterbox included;
  - monotonic pressure ramp; a light first touch draws;
  - 20 real dots: none lost (`bounce_dropped` vs visible);
  - hover, eraser and double-tap;
  - Wi-Fi off mid-stroke; Shift+drag and Ctrl+drag during USB pull and app background: no ghost down, with `input_release`/`owed` captured, plus the trigger→release "close time" (X2);
  - Glide keyboard detach while a key is held; dead keys.
  - **If the tilt sign is wrong:** the orchestrator changes the PROTOCOL §4 tilt formula and fixtures. Wire, with follow-up cards.
- **plan:** the T-023 `--inject-test` tilt and eraser steps were never run (T-025).

**T-181 palm-before-pen-measurement** (G P-PALM measurement)
- **files:** `docs/NOTES.md`; the probe app (`probes/`) only if logging is added there, and then the card must list the exact probe path.
- **acceptance:** [device] the palm vs finger `touchMajor`/`size` distribution, the count of palm-before-pen clicks (`palm_reject` vs host clicks), with no coordinates logged. Decide for or against T-203.

### D8 — Profiles and simplification

**T-182 experiment-knob-inventory** (H KNOB-0)
- **files:**
  - `docs/decisions/0026-experiment-knobs.md`
  - `docs/KNOBS.md` *(new; the table from H §L02)*
  - `backlog/tasks/T-019-gl-jitter-wifilock.md`
  - `backlog/tasks/T-067-client-lock-recenter.md` (status won't-do / closed)
- **acceptance:**
  - The table covers all 33 client extras, 25 host env vars and 4 CLI modes, with file references.
  - The user confirms the GL and `nw` retirement.
  - The T-019 card notes that its Wi-Fi-lock part was superseded by T-089 (F).
  - `board.sh` is re-run.

**T-183 client-retire-experiments** (H KNOB-C1, amended by audit K4)
- **files:**
  - `C/MainActivity.kt`
  - `C/video/VideoRenderer.kt`, `C/video/AdaptivePacer.kt`, `C/video/FramePacer.kt`, `C/video/PerfHint.kt`, `C/video/AndroidPerfHint.kt`, `C/video/RefreshVote.kt`, `C/video/ConstantPlayoutPacer.kt`, `C/video/OperatingRate.kt`
  - `C/session/SessionController.kt` (bench and knob plumbing only)
  - `C/security/Records.kt` (bench only)
  - matching tests in `CT/` (`PerfHintTest`, `RefreshVoteTest`, `ConstantPlayoutPacerTest`, `LockRecenterTest`)
- **Implementer check:** confirm the actual file names under `C/video/` and `C/session/` before starting.
- **acceptance:**
  - Default-path JVM tests pass unchanged: Pacing, AdaptivePacer, SparseFrameNoHold, PresentationScheduling, NewestFrameShown.
  - `tools/pacing` field names are unchanged (or follow T-168's renames with aliases), and `trace7_120hz_excerpt.csv` is kept.
  - [device] Akıcı and Oyun 120 for 2 min each, comparable to NOTES 2026-10-03, compared via T-168's names (`cap_dec_*`, `released=`) or their aliases (audit §4.5).
- **plan:** `VsyncClock` lives in FramePacer.kt:18 and stays. The `rvote` driver is at MainActivity.kt:445, 1790.
  - **Out of scope:** `WifiKnobs.kt`, `tos_ctl`/`tos_video`/`wifi_ll`, WifiLockHolder and the WAKE_LOCK permission stay as debug-only until T-127 reports (audit K4: the "no effect" result was measured on the saturated `nw` stack). T-197 also adds a knob to `WifiKnobs.kt`.

**T-184 client-retire-gl-path** (H KNOB-C2)
- **files:**
  - `C/MainActivity.kt`
  - `C/video/GlPresenter.kt` (delete)
  - `C/stream/GameMode.kt`
  - `CR/layout/activity_main.xml` (`video_gl`)
  - related tests
- **acceptance:**
  - JVM tests pass.
  - [device] 20× bg/fg + 10× mode switches: no black screen and no `gl_*` lines.
- **plan:** about 51 GL references in MainActivity. `codecReportsShown = !glMode` becomes `true`.

**T-185 client-dev-knob-gate** (H KNOB-C3; H add. 3; A A7)
- **files:**
  - `C/MainActivity.kt`
  - `C/session/DevKnobs.kt` *(new)*
  - `C/bench/*` → `client-android/app/src/debug/kotlin/dev/matebridge/client/bench/`
  - `client-android/app/src/main/AndroidManifest.xml`, `client-android/app/src/debug/AndroidManifest.xml`
  - `CT/session/DevKnobsTest.kt` *(new)*
- **acceptance:**
  - [JVM] `DevKnobs.parse` ignores debug-only keys without `dev` and lists them.
  - One `ev=profile` line at `installConfig` with the effective mode, build SHA (T-146) and non-default knobs.
  - The `ev=profile` line repeats the decoder `is_hw` value logged since T-168.
  - The debug `VideoTestActivity` is `exported="false"` if feasible.
  - [device] `--ei jitter 1` without `dev` → `ignored=jitter`; with `dev` → applied.

**T-186 host-retire-experiments** (H KNOB-H1)
- **files:**
  - `HH/Session/SessionServer.swift`
  - `HC/Session/TransportKnobs.swift`
  - `HH/Video/HEVCEncoder.swift`
  - `HC/Video/EncoderKnobs.swift`, `HC/Video/VideoSettings.swift`, `HC/Video/InputColorTags.swift`
  - `HH/Video/SharpnessBench.swift`, `HH/Video/EncodeBench.swift` (knob plumbing only)
  - tests: `TransportKnobsTests`, `EncoderKnobsTests`, `IdleRefreshRefineTests`, `ExperimentKnobTests`, `InputColorTagsTests` (under `HT/`)
- **acceptance:**
  - [XCTest] The removed knob parsers are gone and the remaining tests pass. `ControlSocketTests` and `BsdTcpSocketTests` pass.
  - One `ev=profile` line per stream start (fps, bitrate, codec, encoder profile, non-default env knobs, SHA from T-145).
  - [device] USB and Wi-Fi connect; Bonjour TXT `wol=` updates (T-128).
- **plan:** Bonjour must stay on `HC/Session/BonjourAdvertiser.swift` on the bsd path (SessionServer.swift:227, 1075). Keep `resubmitLast` (the static keyframe path) and drop only the `refresh:` branch.

**T-187 host-encoder-hw-warning** (C PF7-H)
- **files:**
  - `HH/Video/HEVCEncoder.swift`
  - `HH/Video/VideoPipeline.swift`
  - `HH/Session/StreamCoordinator.swift`
  - `HC/Video/` (pure mapping helper)
  - `HT/Video/`
  - `docs/LOGGING.md`
- **acceptance:**
  - [XCTest] Mapping true/false/unreadable → log level and fields.
  - [device] Exactly one `ev=encoder_hw using_hw=1` per pipeline. `using_hw=0|unknown` logs at warning, and the menu shows "software encoder".
  - Do NOT switch to `Require`.
- **plan:** reuse `cadenceReadback`'s `read(_:)` (HEVCEncoder.swift:274-288). Log next to `cadence_setup` (StreamCoordinator.swift:595-596).

**T-188 colour-range-check** (C PF6-M)
- **files:** `docs/NOTES.md`.
- **procedure:** [user]
  - Static page with 1–2 px red, blue and green text on white and black; a 0–255 grey ramp; 0/16/235/255 patches; colour bars.
  - Capture with tablet `screencap` and a Mac screenshot.
  - Run at the default bitrate and at the maximum bitrate.
  - Record the host SHA, mode, bitrate and the tablet `codec_format` line.
- **acceptance:** an explicit range verdict (0→0, 255→255 ±2) and the SDR/4:2:0 limit documented. A follow-up card only on a defect; T-201 only if inconclusive.

### D9 — Scope, setup, docs

**T-189 host-usb-only-profile** (A WI-5; decision 0027; §3.1 prose by the orchestrator)
- **files:**
  - `HH/Session/SessionServer.swift`
  - `HC/Session/BsdTcpSocket.swift` (loopback cases already exist)
  - `HH/Session/UserDefaultsStreamPrefsStore.swift`, or a new `HC/Session/NetworkProfile.swift`
  - `HA/main.swift` (menu toggle)
  - `HT/Session/`
- **acceptance:**
  - [XCTest] A `.loopbackV4Mapped` listener refuses a LAN connect. In USB-only mode, peer classification rejects non-loopback peers.
  - [device] `lsof -iTCP -sTCP:LISTEN` shows 47001/47002 only on 127.0.0.1/::1; `dns-sd -B _matebridge._tcp` shows nothing; USB works.
  - Switching modes restarts the listeners cleanly while no session is live.
  - Codex (security).
- **plan:** bsd listeners at SessionServer.swift:639 and :1031 (the nw variants are gone after T-186). Loopback peer detection is at :1635-1640.

**T-190 client-share-folder-scope** (A WI-6 scope part; decision 0028)
- **files:**
  - `C/files/FilesController.kt`, `C/files/FilesConfig.kt`, `C/files/DavHandler.kt`, `C/files/DavPath.kt` (root parameter only)
  - `C/settings/SettingsCatalog.kt`
  - `CT/files/`
- **acceptance:**
  - [JVM] A root other than `/sdcard` is honoured. Path, encoding and symlink escapes outside the chosen root are refused (extend the DavPath tests).
  - [JVM] Read-only mode → PUT/DELETE/MKCOL/MOVE/COPY/LOCK return 403.
  - [device] The Finder mount shows only the chosen folder.
  - Codex (security).
- **plan:** the root is at FilesController.kt:83-85. MANAGE_EXTERNAL_STORAGE is still needed for path access.

**T-191 client-settings-reset** (H RESET-C; H add. 4)
- **files:**
  - `C/session/Settings.kt`
  - `C/settings/SettingsCatalog.kt`
  - `C/MainActivity.kt` (handler)
  - `C/audio/SharedPrefsOutBufStore.kt`, `C/audio/SharedPrefsSafetyStore.kt`
  - `CT/settings/SettingsResetTest.kt` *(new)*, `CT/settings/SettingsCatalogTest.kt`
- **acceptance:**
  - [JVM] After a reset every getter returns its default, and `matebridge_pairkeys` and `device_id` are untouched.
  - 2-step confirm; `ev=settings_reset` is logged with no values.
  - [device] After `audio_buf_bursts` growth, a reset gives `buf_source=default`.

**T-192 host-settings-reset** (H RESET-H)
- **files:** `HA/main.swift`, `HH/Session/UserDefaultsStreamPrefsStore.swift`, `HC/Video/StreamPrefsStore.swift` (`removeAll`), `HT/Video/`.
- **acceptance:**
  - [XCTest] `removeAll` on the store.
  - Resets USB mode, clipboard and display-keep (T-167). Keeps approvals and Keychain.
  - [device] The next session uses mode defaults, and the tablet reconnects without a prompt.

**T-193 readme-plan-refresh** (H DOC-1; H add. 8)
- **files:** `README.md`, `docs/PLAN.md` (hardware table; Phase 4/5 status lines; the new phase-6 section is written by the orchestrator separately).
- **acceptance:**
  - No "Phase 0 / Nothing usable" text.
  - Layout lists `tools/`, `install-apk.sh`, `usb-mode.sh`, `bundle-host.sh`.
  - Known limits are stated (Wi-Fi vs USB numbers; display grace or keep; the decoder-gap status after D3).
  - A "Last verified" pair with SHAs and OS builds.
  - The stale PLAN.md:179 "~90 fps / 13–15 ms" line and PLAN.md:10 "Model/çözünürlük: ?" are corrected.
  - A link to `docs/RECOVERY.md`.
  - Mode guidance (audit §3 PF5 residual): in Akıcı/Performans the virtual display stays at 120 Hz, so with keyboard-only work (panel at 60 Hz) Mac apps still render 120 fps while ~60 are shown. For long keyboard sessions, prefer Netlik 60 (or Oyun 60 for games).

### D10 — Soak

**T-194 soak-8h-week** (H SOAK-1 run; D §X13)
- **files:** `docs/NOTES.md`.
- **acceptance:** [device/user]
  - Every result header names both SHAs, the macOS and HarmonyOS builds, transport, mode, resolution, target and real Hz, bitrate, content and duration.
  - An 8 h real-work run shows no monotonic growth in threads, FDs or PSS/RSS (slope below an agreed threshold).
  - Restart-requiring events are counted. Include sleep overnight and USB↔Wi-Fi switching during the day.
  - Then 1 week, with a daily summary line.
  - Anything not run is listed as "not run".

### G — Measurement-gated or low value

**T-195 core-congestion-controller** (F F-2; 0023 branch (c); gated on T-127 showing "go adaptive")
- **files:** `HC/Video/CongestionController.swift` *(new)*, `HT/Video/CongestionControllerTests.swift` *(new)*, a golden replay file under `HT/Video/` (from anonymised T-127 `ev=tcp` numbers).
- **acceptance:** [XCTest]
  - Step response to an srtt spike: the bitrate falls within one srtt and recovers no faster than the slope.
  - Never above the ceiling or below the floor; no oscillation at constant RTT.
  - The replay golden matches.
- **plan:** baseline srtt = windowed minimum. Budget ≈ rate × 20 ms, with a floor of one average frame. Use `sbbytes`, not the cwnd-based unacked estimate.

**T-196 host-wifi-adaptive-send** (F F-3; gated on T-127 and T-195; §0x03 "ceiling" prose)
- **files:**
  - `HC/Video/SocketVideoTransport.swift`
  - `HC/Session/BsdTcpSocket.swift` (read-only accessors)
  - `HC/Session/TransportKnobs.swift`
  - `HH/Session/SessionServer.swift` (VideoLink)
  - `HH/Session/TcpSocketProbe.swift`
  - `HH/Session/StreamCoordinator.swift`
  - `HH/Video/VideoPipeline.swift`
  - `HT/`
  - `docs/LOGGING.md`
- **acceptance:**
  - With the knob off: byte-identical behaviour ([XCTest] fake socket).
  - With it on: admission blocks while fake sbbytes exceed the budget, and wakes on writable or tick.
  - `video ev=adapt` once per second.
  - [device] T-127 topology 3: underruns and srtt p95 vs the baseline at equal or better latency p95; static-text sharpness unchanged.
  - Codex (transport).

**T-197 client-ctl-lowat-knob** (F F-5; gated on T-127 showing uplink stalls)
- **files:**
  - `C/session/SessionController.kt`
  - `C/session/QuickAck.kt` (fd helper) or `C/session/NotSentLowat.kt` *(new)*
  - `C/session/WifiKnobs.kt` (or `DevKnobs.kt` after T-185)
  - `C/MainActivity.kt` (knob parse only)
  - `CT/session/`
- **acceptance:**
  - [JVM] Knob parse plus a setsockopt wrapper; on failure, log once and leave the session unaffected.
  - Log `ctl_lowat_kb=`.
  - [device] Count congested episodes and merged hover samples vs the baseline; reconnects must not rise.
  - Default off.

**T-198 host-pen-playout-experiment** (G P-M04c; decision 0024; gated on T-179)
- **files:** `HC/Input/PenPlayout.swift` *(new)*, `HC/Input/InputPipeline.swift`, `HH/Input/InputController.swift`, `HT/Input/`.
- **acceptance:**
  - [XCTest] Replay with an injected 30 ms burst → spacing within ±1 ms of `dt` within budget; no reordering; boundaries, pressure and position are bit-exact.
  - [XCTest] CONTACT 1→0, release-all and the watchdog flush immediately. A non-PEN message behind queued pen samples waits until they are flushed.
  - [XCTest] A budget overrun collapses to immediate posting. A loopback peer → off.
  - [device] Krita Wi-Fi A/B using T-171 ages; USB unchanged.
  - Codex `--high` (pen injection).
- **plan:** DispatchSourceTimer on the input queue; never block the session queue (`queue.sync` back-pressure); tolerate dt = 0 runs and 1 ms quantisation (G add. 4).

**T-199 host-stale-input-policy** (G P-M04d implementation; decision 0025; gated on T-171 data; §4/§7 prose)
- **files:** `HC/Input/InputStateMachine.swift` and related `HC/Input/InputStateMachine+*.swift`, `HC/Input/InputPipeline.swift`, `HC/Input/InputAge.swift` (from T-171), `HT/Input/`.
- **acceptance:**
  - [XCTest] For age > T_stale: hover and relative motion collapse; new presses and their releases are ignored as a pair; every release of an *applied* press is still applied; with an untrustworthy offset the policy is off.
  - Fuzz tests still pass.
  - Codex `--high`.

**T-200 host-display-keep-on-failure** (D P-5; D add. 1; gated on T-166)
- **files:** `HH/Video/VideoPipeline.swift`, `HH/Session/StreamCoordinator.swift`, `HC/Video/PipelineFailurePolicy.swift` *(new)*, `HT/Video/`.
- **acceptance:**
  - [XCTest] Error kind × `displayOnline` → keep or invalidate.
  - [device] Stopping capture from the menu-bar indicator (SCK -3817) recovers without window movement; the display-sleep behaviour matches T-166.
- **plan:** `onFailure` carries the kept display through the mailbox (`pipelineFailed(…, display:)`), with single ownership. Today every failure invalidates (VideoPipeline.swift:290-301), and nothing rebuilds during grace (StreamCoordinator.swift:513).

**T-201 host-chroma-bench** (H IQ-1; gated on T-188 being inconclusive)
- **files:** `HH/Video/SharpnessBench.swift`, `HC/Video/` (pure metric helpers), `HT/Video/`.
- **acceptance:**
  - [XCTest] The metric on synthetic inputs.
  - The bench prints per-pattern ΔE or CbCr PSNR plus luma PSNR at 30/60/80 Mbps.
- **plan:** the current reference chroma is pre-averaged (SharpnessBench.swift:41-46, 121).

**T-202 host-crash-restart-agent** (D P-8; gated on T-147; draft its decision then)
- **files:** `HA/LoginItem.swift`, `scripts/bundle-host.sh` (embed `Contents/Library/LaunchAgents/*.plist`), `HT/Session/` (policy).
- **acceptance:**
  - [device] `kill -SEGV` → back within ~10 s and the tablet reconnects.
  - Quit does not relaunch.
  - TCC grants persist.
  - Crash loops are throttled (`ThrottleInterval`).

**T-203 client-palm-size-filter** (G P-PALM implementation; gated on T-181; 0006 amendment)
- **files:** `C/input/TouchTracker.kt`, `C/input/MotionEventAdapter.kt`, `C/input/Model.kt`, `CT/input/`.
- **acceptance:**
  - [JVM] The size gate and its interaction with HOLD_MS (40 ms), pinch and scroll. Releases stay unconditional.
  - Codex (input state).

---

## 4. Not carded

| Proposal | Reason |
|---|---|
| D P-9: fallback to main-display capture when `CGVirtualDisplay` is unavailable | Research only. Revisit after the T-147 rehearsal; listed as §5 Q12. |
| C L03-H: trim host compressed-frame copies | Already measured small: `cap_to_sent` − `enc` ≈ 0.3 ms p50 (NOTES:401, 405). The real bug in it (CMBlockBuffer contiguity) moved to T-162. Revisit only if T-170 keyframe `conv+write` p99 > 0.5 ms. |
| H add. 7, L03 client side: avoid `copyOfRange`/`r.bytes` copies | Measured small (T-076/T-077; `queueInputBuffer` dominates). Act only if GC correlates with stalls (AudioArrivalMeter `gc_*`). |
| E optional wire items: input `seq` + `INPUT_ACK` 0x24; STATS p95/render fields | Deferred by E. T-171 gives host-side age with no wire change, and T-168 gives logs. Revisit after T-174 if the residual is unexplained. |
| F A-4: non-audio H→C control ignores the low-water mark | Low volume, no observed harm. Mention in T-196 if it is ever built. |
| F: split control and audio sockets | A3. The head-of-line blocking is in the AP queue, and audio is already its own flow. |
| Review A4: UDP/QUIC datagram video | Only after 0023 step (c) and only if retransmission-driven p99 dominates. Revisit trigger in 0023 and 0010. |
| Review PF2/PF5/D8 profiles; "Wi-Fi balanced" profile | Profiles already exist (0013, 0014, 0016; T-143). The Wi-Fi part is covered by T-178. |
| Review PK5 "finger off / navigate only" policy | Already the default (decision 0006 §2, TouchTracker 1.2 s gate, "Parmak dokunmasını tamamen kapat"). Residual handled by T-181/T-203. |
| Review PK8/A5 local cursor layer | Pen trail exists (T-056) and is off by user choice (T-064). Wait for T-174 optical data. |
| Review PK7/X10 keyboard matrix | Mostly done (NOTES 2026-09-30 l.245). Remaining items are in T-180. |
| Review V10 keep gate/resync/coalescing | Already done (T-121, T-122); nothing to card. |
| Review 4:4:4 experiment | Already a PLAN Aşama 5 item; blocked by decoder support; X11 first (T-188). |
| H add. 6: audio generation overlap (500 ms join, no-op interrupt) | Low (it falls back to SHARED/TRACK). Counted in T-164 and T-194 checklists; card only if counts show it. |
| D add. 3: `Thread.sleep` in `selectMode` on the cooperative pool | Low. Noted in T-165 plan; fix only with display code changes. |
| D add. 4: recreate path has no fallback | Low. Noted in T-165 plan. |
| D add. 7 and C/D: decision 0016 "her mod değişimi" wording | One-line orchestrator doc fix when drafting 0020. |
| F: mark T-019 Wi-Fi-lock part superseded | Done inside T-182 (T-019 closes as won't-do). |
| H L02: split MainActivity into SessionUi/VideoHealth/InputBinding/Settings | The review says no wide refactor before H01–H05 close. T-159 already extracts VideoHealth, and T-183 … T-185 shrink MainActivity. Revisit after D3. |
| Review A1 three-owner architecture (Display/Session/MediaOwner) | Direction only. Implemented narrowly by T-159/T-160/T-161 (client media), T-162 (encoder owner) and T-165/T-200 (display owner). No framework or DI. |
| Review LM8 "oldest-work age" gauges on both sides | Partly covered by T-168 (percentiles) and T-170 (join). A dedicated gauge is not carded until the T-127/T-174 analysis shows a gap. |
| Audit PF5 residual: Mac apps render 120 fps in Akıcı/Performans while keyboard-only work drops the panel to 60 Hz | Low (energy/thermal, not correctness). Decision 0016 forbids automatic mode switching, because 60↔120 recreates the display. Documented as mode guidance in T-193; card only if the user asks for an energy profile. |
| Review LM7 "300 kB over 30 Mbit/s ≈ 80 ms" | Illustrative. F is right (audit K2): the delay is AP/driver queueing; the raw link is ~410 Mbit/s. Noted in the T-127 plan; nothing to card. |
| Review M06 "permission/startup check" | Accessibility is already re-read and shown in the menu. Screen Recording loss is documented in the T-147 runbook. No code card. |

---

## 5. Open questions for the user

1. **Second access path (T-147, 0020):** the rollback screen is taken to be the headless 1920×1080 placeholder (NOTES.md:160; the HDMI-dummy question is dropped per the coverage audit K3). Which remote path do you rely on when the tablet shows nothing (Parsec only, or also SSH / macOS Screen Sharing)? Is FileVault on?
2. **Display keep time (0020):** default 10 s, 5 min, 30 min or "until Quit"? Answer after T-166 shows whether a parked display survives display sleep and system sleep.
3. **Pairing flow (0018, T-155):**
   - Keep the Parsec/orphan approval flow? The proposed design keeps it: you confirm the code on the tablet before or after switching to Parsec.
   - Do you accept that any pairing must now be started by a tap on the tablet ("Yeni Mac bulundu — Eşleş"), including after "Onaylı cihazları unut" on the Mac?
4. **CI (0022):** OK to use GitHub Actions (repo is public, so runner minutes are free)? Advisory for the first week, then required?
5. **Retire experiments (0026):** confirm retiring the GL presentation path and the Network.framework (`nw`) sockets, both informally "kept as option".
6. **USB-only profile (0027):** do you want a "Yalnız USB" mode? The default stays USB + Wi-Fi.
7. **File sharing scope (0028):** default folder (`Download/` or a "MateBridge" folder), keep a "tüm depolama" option, and offer read-only?
8. **Wi-Fi priority (0023, T-127):**
   - Is Wi-Fi meant to become a primary path, or stay a fallback? This sets the H03 priority.
   - Can you run the Mac-on-Ethernet test?
9. **Pen on Wi-Fi (0024):** still "acele yok, en sona"? You said you draw over USB. T-179/T-198 can stay parked.
10. **Stale input (0025):** acceptable that, after a long Wi-Fi stall, presses older than about 300 ms are ignored (releases always applied)?
11. **Crash restart (T-202):** should the host relaunch itself after a crash (LaunchAgent KeepAlive), or is a manual relaunch through the runbook enough?
12. **Private API break (D P-9):** if a macOS update breaks `CGVirtualDisplay`, do you want a reduced-quality fallback that streams the main or placeholder display?
13. **Optical test (T-174):** do you have a 240 fps phone camera and a tripod, and will you run ≥3 sessions per condition on different days?
14. **Latency budgets (B1):** agree that budgets are set after the optical baseline rather than adopting the review's 45/70 ms now?
15. **Soak (T-194):** willing to log an 8 h workday and then a week, with daily one-line summaries?
16. **Palm (T-181/T-203):** have you seen any palm clicks before the pen comes into range? If not, T-203 stays parked.
17. **Device transfer (T-154):** do you use Huawei Phone Clone or a similar transfer? Low impact either way.

---

## 6. Traceability: review IDs → cards

| ID | Cards / disposition |
|---|---|
| H01 | T-150 (incl. plaintext-ack migration gate), T-151, T-156, T-157 (decision 0018). Adjacent: T-152, T-153, T-155 |
| H02 | T-158, T-159, T-164 (decision 0019) |
| H03 | T-127 (re-scope), T-176, T-177, T-178; gated T-195, T-196, T-197 (decision 0023) |
| H04 | T-165, T-166, T-167; gated T-200 (decision 0020) |
| H05 | T-168, T-170, T-172, T-174 (decision 0021); T-169 |
| M01 | T-160 |
| M02 | T-162 (seam extraction is its explicit step 1) |
| M03 | T-158, T-161, T-164 |
| M04 | T-171, T-163 (freshness/repeat), T-172 (doc bound), T-179; gated T-198, T-199 (decisions 0024, 0025) |
| M05 | T-153, T-189, T-190, T-155 (decisions 0027, 0028) |
| M06 | T-147, T-148; gated T-202. Fallback (P-9) not carded: research, §5 Q12 |
| M07 | T-149, T-173, T-194; seams T-158, T-162 |
| L01 | T-145, T-146, T-193 |
| L02 | T-182, T-183, T-184, T-185, T-186 (decision 0026) |
| L03 | T-175 (input side). Host and client copy trims not carded: measured small (see §4) |
| X1 | T-157 (JVM parts in T-150) |
| X2 | T-180 (device matrix incl. close time), T-163 |
| X3 | T-159 (JVM + fault extra), T-164 |
| X4 | T-160 |
| X5 | T-162 |
| X6 | T-164 (code side T-161) |
| X7 | T-166 |
| X8 | T-127 |
| X9 | T-180 |
| X10 | T-180 (mostly already done, NOTES 2026-09-30) |
| X11 | T-188; gated T-201 |
| X12 | T-169 |
| X13 | T-147 (recovery rehearsal), T-194 (soak) |
| D1 | T-145, T-146, T-147, T-148, T-149 |
| D2 | T-150 … T-157 |
| D3 | T-158 … T-164 |
| D4 | T-165, T-166, T-167 (T-200 gated). "Separate bitrate change from display life" is already done (T-106); in-session bitrate is T-177 |
| D5 | T-168 … T-175 |
| D6 | T-127, T-176, T-177, T-178 (T-195 … T-197 gated) |
| D7 | T-179, T-180, T-181 (T-198, T-199, T-203 gated). The finger-vs-drawing policy exit is already met by decision 0006 |
| D8 | T-182 … T-188. Profiles mostly already exist (0013, 0014, 0016) |
| D9 | T-189 … T-193, T-148 (login check), T-147 (setup and recovery page) |
| D10 | T-194 |
| PF5 (GPU part; audit §3) | Already addressed for games (Oyun 60, 0016). Non-game residual documented in T-193; not carded (§4) |
| PF7 (host + client) | T-187 (host encoder), T-168 (client decoder `is_hw`/`sw_only`) |
| SE3 (host half; audit §3) | Confirmed. Its gaps are key repeat → T-163 and the 1.5–5 s kernel-buffered stale window → T-172 (doc bound) and gated T-199 |
| p11 R-tag rule (M01, M02, M03, M06, L03 start with a deterministic failure scenario) | First acceptance item of T-160 (M01), T-162 step 1 (M02), T-161 (M03), T-147 and T-148 (M06), T-175 (L03, measure first) |

**Additional findings not in the review**, all carded:
- A A1 → T-152
- A2 auto-connect without picker → T-150/T-151
- A2 migration on plaintext ack → T-150 (folded in, per coverage audit §3 A2/§4.7)
- A2 localhost token → T-150 acceptance + T-153
- A A2/A3/A5/A6/A7 → T-151/T-156/T-154/T-155/T-185
- B add. 1–5 → T-159/T-160/T-161
- C add. 1–6 → T-162
- D add. 1–2, 5–6 → T-165/T-166/T-200
- E add. 1–6 → T-168/T-169/T-170/T-172
- F A-1/A-2/A-3/A-5 → T-176/T-177/T-127
- G add. 1–7 → T-163/T-172/T-171/T-198/T-179/T-181/T-175
- H add. 1–5, 8 → T-149/T-185/T-191/T-158/T-162/T-193

---

## 7. Notes for reporting to the user (coverage audit §4.1–4.2)

- **Translation artifacts.** Four report "corrections" come from claims.md wording, not from the review, so do not present them as review errors:
  - C on LM4 ("not older"): the useful fact stays: the tablet under-reports by about 6.6 ms;
  - G on IN10 ("not a control interval");
  - B on V8 ("not async");
  - E on PF1 ("received, not captured").
- **LM7.** F is right: link capacity is not the encoder rate.
- **Rollback screen.** It is the headless 1920×1080 placeholder, not a physical monitor. H's S3 "rollback exists in practice" overstated this.
- **Wi-Fi TOS/`wifi_ll` knobs.** They stay until T-127 re-measures them.
- **Severity notes.**
  - M02: Low–Medium (C), against the review's Medium.
  - W4 "Mac input": take F's impact list (the audio downlink and a false silence release share the session queue). Measure first (T-175).
- **Baseline test status.** No one has a recorded `check.sh` pass at a30c769 yet; T-147 records one.


---

## 8. Post-QA changes (after four QA reviewers checked all cards; this section overrides §2–§6 where they differ)

- **T-186 split:**
  - T-186 now covers only the `nw` socket retirement. Its depends_on is [T-182, T-171].
  - The new **T-204** `host-retire-encoder-knobs` covers idle refresh, FRAME_DELAY, PRIO_SPEED, H264_PROFILE and INPUT_RETAG, plus the host `ev=profile` line. It depends on [T-182, T-177, T-145] and on decision 0026.
  - HEVCEncoder chain: T-162 → T-170 → T-176 → T-177 → T-204 → T-187. T-201 depends on T-204.
- **T-150 split:** the AUTO-mode USB migration gate moved to the new **T-205** `client-migration-auth-gate`, which depends on [T-150] and decision 0018. T-157 depends on T-154, T-156 and T-205 too.
- **T-189** no longer depends on T-186. While "Yalnız USB" is on, it forces the `bsd` listeners. The two cards are serialized on `SessionServer.swift`.
- **T-159** no longer edits `SessionMachine.kt` (VideoHealth's generation rule replaces the frame-counter reset). It is therefore out of the SessionMachine/SessionController chain, which is now T-150 → T-205/T-156 → T-160 → T-197.
- **depends_on additions:** T-197 +T-171; T-201 +T-204 (replacing T-186); T-202 +T-148.
- **Gate data:**
  - T-127 records the explicit "go adaptive" rule for 0023, plus `input_age`, `merged=`, the user's static-text verdict and a replay trace under `tools/wifi-trace/`.
  - T-179 records the clustering rule that unlocks T-198.
  - T-181 records the palm/finger size within the first 40 ms or 16 px.
  - The gated cards T-195 to T-203 read exactly these outputs.
- **Decisions updated after QA:** 0018 (pending-record expiry, no auto-connect while a pending record exists, forget on a live session, cancel semantics, audio gate), 0019 (fault timer start point, generation definition, generic fault input, delayed debug fault trigger), 0026 (T-204).
- **QA reports:** `qa-1.md` … `qa-4.md` in this directory.
