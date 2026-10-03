# Coverage audit: review PDF → claims.md → verification reports (HEAD a30c769)

Inputs read in full: PDF pp. 1–25; `claims.md`; `verify-{A-security, A2-adversarial, B-client-video, C-host-video, D-display, E-measurement, F-network, G-input, H-hygiene}.md`. A2-adversarial was not on the input list, but it exists and refines A, so it is included.
Read-only: no repo file or git state was changed. Line numbers are at HEAD a30c769.

## 0. Summary

| Area | Result |
|---|---|
| PDF → checklist | No High/Medium/Low finding, D-step, X-row or budget is missing. 16 smaller substantive points are missing (§1.1). 6 points are mistranslated or lossy (§1.2), and 4 of those caused "corrections" in the reports that are really translation artifacts. |
| Checklist → verdicts | Every ID has at least one verdict, except the **p11 priority statement**, which has none. **8 IDs are only partly covered:** PF5 (GPU/Game-60 part), PF7 (client decoder part), A2 (control/input-model, decode+SurfaceView and crypto bullets), SE3 (host half), A1 (host SessionOwner), D3 (host part), F2 (encoder part), and p11. I verified all of them myself (§3). |
| Cross-report | 4 factual contradictions (§4.1): the decision-number collision, LM7, the "physical monitor" rollback, and the Wi-Fi TOS/`wifi_ll` knob retirement. 4 translation-artifact corrections (§4.2). 5 duplicate work items (§4.3). 1 severity split (§4.4). Many cards edit the same files and need ordering (§4.5). Report-local IDs collide with claim IDs (§4.6). |

---

## 1. PDF → checklist (claims.md)

### 1.1 Substantive points missing from claims.md

Each row gives the page, the point and the verdict, with evidence where verification was needed.

| # | p. | Missing point (PDF) | Verdict / evidence |
|---|---|---|---|
| O1 | 2, 24 | The verdict rests on static review plus repo notes. **No performance test was run on Mac/MatePad.** The report "is not a code change or performance certificate". The absence of a Critical finding "is not guaranteed". | Meta. Consistent: no verifier ran device tests either. |
| O2 | 3 | Scope assumption: the target is personal Mac mini + MatePad use. Multi-user cloud, App Store distribution and general Android compatibility are **not** mandatory targets. | CONFIRMED, consistent with `docs/PLAN.md:5` ("Tek kişi, kendi evi/masası. Dağıtım, mağaza, başka cihaz yok."). |
| O3 | 3 | The reviewer **did not run `scripts/check.sh`**, did not build Swift/Android, and did not run the Swift crypto-vector generation. "Tests passing is not claimed." Only `gen.py --check` and the fixture-name match were run. | NOT VERIFIABLE here: no toolchains, and no verifier ran check.sh. H re-ran only `gen.py --check` (exit 0). **Implication:** P3's "strong tests" is a count, not a pass result. The first device/CI step should record a `check.sh` pass at a30c769. |
| O4 | 4 | The Mac app runs **in the user session**. VT encodes "mostly" HEVC, which implies an H.264 path. | CONFIRMED. User session: D/M06 (`LoginItem.swift:58`, `SMAppService.mainApp`). H.264: C/W1 (`MATEBRIDGE_CODEC=h264`). |
| O5 | 4 | Thread-map conclusion: "a single thread would add latency; more threads per module isn't the fix. Simplify the lifecycle of time-sensitive resources and which generation may own which output." | Not in claims W4, but **H verdicted it** ("closing verdict paragraph": agree). Covered. |
| O6 | 5 | The V-table "latency/load source" column holds claims that were dropped: (a) V1 `queueDepth=5` ≠ 5 frames of delay; (b) V2 replacing the raw frame before encode does not break the HEVC chain; (c) V3 "don't judge `RealTime=false`/fast as slow by its name"; (d) V5 a kernel write ack ≠ the peer received or displayed it; (e) V6 a large frame or a lost segment delays the following bytes (HOL), and a record is unusable until complete; (f) "showing a newer output **after decode** is possible" (p5 text). | (a)–(e) CONFIRMED as stated. They are design truisms, and C/B evidence covers them: newest-wins in `FrameGate.swift:73`; RealTime=false at `HEVCEncoder.swift:159` was chosen by measurement (T-047/T-053); full-record accumulation at `Records.kt:249-300`. (f) **ALREADY IMPLEMENTED**: `SlotReleaser.kt:60-68` discards the held buffer when a newer frame gets the same slot (newest wins post-decode, T-065). |
| O7 | 6 | Frame periods: 60 Hz = 16.67 ms, 120 Hz = 8.33 ms, 144 Hz = 6.94 ms. A missed present slot costs one period at that scale. | CONFIRMED (arithmetic). E's LM6 worst-case ready→slot (~27–35 ms at 120 Hz) builds on this. |
| O8 | 6 | LM8 caveats: an input ACK does **not** mean the target app processed the event. 240 fps video ≈ 4.17 ms resolution and needs no device clock sync. | CONFIRMED. E W3 and G P-M04b measure injection age only and say so. E W5 uses 240 fps / 4.17 ms. |
| O9 | 7 | IN9: the platform may not apply unbuffered dispatch the same way every time, so **history support must be kept**. | CONFIRMED kept: `MotionEventAdapter.kt:162-190` carries all history (G IN8). No card proposes removing it. |
| O10 | 8 | PK2: "a higher tilt resolution in the protocol does not create samples the source never produced". This argues against widening the protocol. | CONFIRMED. Tilt is already `i16` normalized −1…1 (`docs/PROTOCOL.md:262-263`), far finer than the 1–5 distinct in-contact values (NOTES l.46). No protocol change is warranted. |
| O11 | 8 | PK5: "don't unconditionally suppress every finger event; it would break daily use". | Covered by G PK5. The existing gate is narrow (pen-in-range + 1.2 s, `TouchTracker.kt:412-413,445`), with an opt-in "finger off". |
| O12 | 11 | "For R-tagged findings (M01, M02, M03, M06, L03) the first job is to complete the evidence with a **deterministic failure scenario**." | See the p11 verdict in §3. The reports' items comply (B P2/P3, C M02-H barrier tests). They need test seams first (H TESTSEAM-1; `host-mac/Package.swift:18` has only the `MateBridgeCoreTests` target). |
| O13 | 11 | "High does not mean only a security hole; it also covers usage/verification gaps that block the daily main-screen goal." "USB-heavy drawing reduces H03's effect." | CONFIRMED. F/H03 (USB srtt ~4.7 ms, send queue 0, NOTES l.637); PLAN.md:181 (user draws over USB). |
| O14 | 18 | M07 rationale: the expensive bugs are OS/driver behaviours (codec/surface lifecycle, TCC, virtual display, Wi-Fi jitter, Harmony panel policy, input release during outages). Pure tests can model them but cannot verify them. Same-condition comparisons make "it was smoother before" checkable. Track failure contracts rather than test counts. The review made no test/code change and does not claim M07 closed. | CONFIRMED in substance. H notes that `MateBridgeHost`, `VideoRenderer` and `SessionController` have no tests (Package.swift:18). |
| O15 | 19 | L03 priority caveat: "not proven to be the biggest bottleneck; must not be put ahead of Wi-Fi and render-health problems". | CONFIRMED. All three L03 verifiers (C, G, H) rate it Low and say "measure first". Host post-encode ≈ 0.3 ms p50 (NOTES l.401/405); client copy 0.11 ms (NOTES l.437). |
| O16 | 19 | L01 impact: it is hard to know which encoder/pacer/sleep fix an APK contains, and old "ceiling" notes or temporary modes get taken as product truth. | CONFIRMED, and the PLAN itself is affected: `docs/PLAN.md:179` still cites the "~90 fps" decoder ceiling and "13–15 ms" encode, both disproven (NOTES l.1104). H P1 found this. |
| O17 | 20 | A2: "no proven benefit from a WebView/canvas image path". A3: "a separate socket alone gives no Wi-Fi priority". | CONFIRMED. There is no WebView in `client-android/app/src/main` (the only Canvas user is the display-only `overlay/PenOverlayView.kt`). A3: F (control srtt still rises despite the separate socket and AC_VO, NOTES l.970-991). |
| O18 | 13, 14 | H02 impact: "the user may type into a window they can't see, or continue a drag at the wrong place". H05: "not a benchmark-honesty accusation; a missing metric contract". H01-Why: "'this Mac may have forgotten the key' and a fake host are not separated as a blocking trust decision". | Covered. B/H02. E/H05 (labels). A2 (amber text "Mac bu tableti tanımıyor" blames the Mac; `MainActivity.kt:2053-2070`). |

Minor, non-substantive omissions (no action needed):
- p10 SE3 praise ("not treated superficially").
- p21 "I wouldn't cover a trust/health bug with performance tuning".
- p22 D10 "only then accept a main screen needing less alternate access".
- p9 PF3 "not overcome by a `setFrameRate` call or the 144 Hz panel spec". E covers this: NOTES l.1068 records that `Surface.setFrameRate` was tried.
- p9 PF7 "don't derive the optimum from a single run". E flags PF1's single runs.

### 1.2 Mistranslations / lossy translations in claims.md

| # | ID | PDF (p.) | claims.md | Effect on reports |
|---|---|---|---|---|
| T1 | PF1 | "alınan/gösterilen" + "yalnız yoğun, saniyede **en az 100 kare** alınan pencereler" (p9) | "captured/shown", "dense windows" | E corrected "received, not captured" but **attributed the error to the review**. The review wrote "alınan" (received), so the error is in claims.md. The ≥100 fps selection filter was dropped in claims.md; E restored it. |
| T2 | SE4 | "Decoder give-up, yalnız video kesilmesi ve eski reader teslimi bu ayrımı mutlaka gerekli kılıyor" (p10) = three cases (give-up, a video-only cut, old-reader delivery) that make the separation necessary | "Decoder give-up only cuts video & old reader delivery needs separation" | The claims.md wording asserts a different fact. B's SE4 verdict is still right on substance. |
| T3 | IN10 | "25 ms **kontrol aralığı**" (p7), i.e. check/tick interval | "25 ms control interval" | G's correction "it's the UI input ticker, not a control interval" corrects a translation artifact. G's fact (`INPUT_TICK_MS = 25`, `MainActivity.kt:944-953`) matches what the review meant. |
| T4 | V8 | "Asenkron yürüyen giriş/çıkış thread'leri" (p5), i.e. input/output threads running independently | "async in/out threads" | B's "PARTIALLY CORRECT: synchronous buffer mode, not async-callback mode" is technically true, but the review did not claim callback mode. Downgrade to CONFIRMED with a wording nit. |
| T5 | LM4 | "captureTimeUs ise send içindeki **eski** stamp olarak taşınıyor" (p6): most plausibly "the existing/legacy stamp inside send()" | "a different old stamp" | C's correction "the wire stamp is **not older**, it lies ~6.6 ms after the callback" rebuts a reading the review probably didn't intend. C's fact is correct and important: the client **under**-reports by ~6.6 ms (NOTES l.401). Keep the fact and drop the "review was wrong" framing. |
| T6 | V3 | Load column: "Varsayılan fast profil RealTime=false; adından hareketle yavaş diye hüküm verilemez" (p5) | omitted (PF7 keeps only "keep RealTime=false") | No effect. C V3 covers it (`HEVCEncoder.swift:159`). |

---

## 2. Checklist → verdicts (every claim ID)

Verdict abbreviations: C = CONFIRMED, PC = PARTIALLY CORRECT, I = INCORRECT, NV = NOT VERIFIABLE IN CODE, AA = ALREADY ADDRESSED.
In the Report(s) column, "§3" means I verified the item myself (see §3).

| ID | Report(s) | Verdict(s) | Coverage |
|---|---|---|---|
| S1 | H | C | full |
| S2 | H | C | full |
| S3 | H | C (with a factual error, see §4.1 K3) | full |
| P1 | H | C (+ PLAN.md stale) | full |
| P2 | H | C | full |
| P3 | H | C (counts; no pass result, see O3) | full |
| P4 | H | C | full |
| P5 | E | C | full |
| W1 | B (client), C (host) | C / C (B nit: sync mode, see T4) | full |
| W2 | F | C (WMM classes already set, T-124) | full |
| W3 | A | PC | full |
| W4 Mac capture | C | C | full |
| W4 Mac encode | C | PC (more submit threads than listed) | full |
| W4 Mac session | D | C | full |
| W4 Mac input | F, G | C / C (severity differs, §4.4) | full |
| W4 Mac socket | C | PC (first write is synchronous on the caller) | full |
| W4 Android UI | G | C | full |
| W4 Android session | F | C | full |
| W4 Android codec | H | C | full |
| W4 Audio | H | C (cross-generation overlap nuance) | full |
| W4 closing para (O5) | H | agree | full |
| V1 | C | C | full |
| V2 | C | C | full |
| V3 | C | C | full |
| V4 | C | C | full |
| V5 | C | C (`nw` path allows 2 in flight) | full |
| V6 | B | C | full |
| V7 | B | C | full |
| V8 | B | PC (partly a T4 artifact) | full |
| V9 | B | C (3 pacers + bypass) | full |
| V10 | B | C / AA (T-121/T-122); post-decode newest-wins AA (§1.1 O6f) | full |
| LM1 | C | C | full |
| LM2 | E | C | full |
| LM3 | E | C | full |
| LM4 | C (+E in H05) | C, AA as known (T-072 open question); "not older" correction is partly a T5 artifact | full |
| LM5 | E | C (bias direction: under-reports) | full |
| LM6 | E | PC (D cap vs slot bound conflated) | full |
| LM7 | E, F | **C vs PC (conflict, §4.1 K2)** | full |
| LM8 | E | proposal, partly AA | full |
| IN1 | G | C | full |
| IN2 | G | C | full |
| IN3 | G | C | full |
| IN4 | G | C | full |
| IN5 | G | C | full |
| IN6 | G | C | full |
| IN7 | G | C | full |
| IN8 | G | C | full |
| IN9 | G | C | full |
| IN10 | G | C (minor; partly a T3 artifact) | full |
| IN11 | F | C (+ the kernel buffer hides congestion) | full |
| PK1 | G | C | full |
| PK2 | G | C | full |
| PK3 | G | NV (code facts C) | full |
| PK4 | G | C | full |
| PK5 | G | AA (decision 0006) + residual | full |
| PK6 | G | C | full |
| PK7 | G | AA (mostly) | full |
| PK8 | G | C (pen trail exists, T-056/T-064) | full |
| PF1 | E | C (T1 misattribution) | full |
| PF2 | E | C (144 Hz moot) | full |
| PF3 | E | C | full |
| PF4 | C (host), H (client) | C / C | full |
| **PF5** | D (mode-switch part only) | AA (0016) for that part | **partial: GPU-load / Game-60 part has no verdict. Verified in §3.** |
| PF6 | C | C | full |
| **PF7** | C (host encoder) | PC / partly AA | **partial: "verify hardware decoder selected" (client) has no verdict. H D8 mentions it in passing. Verified in §3.** |
| SE1 | A (+A2) | C (D2D nit) | full |
| SE2 | A | PC | full |
| **SE3** | B (client half) | C with video gap | **partial: host half (input-silence release, pen watchdog, sessionEnded) not verdicted. Verified in §3.** |
| SE4 | B | C (T2 wording) | full |
| SE5 | D | C | full |
| SE6 | H | C | full |
| SE7 | B (M01/M03), C (M02) | C / C | full |
| SE8 | H | C | full |
| **p11 priority statement** | — (F and D touch it only in severity notes) | **none** | **no verdict entry. Verified in §3.** |
| H01 (Problem/Why/Attack/Where/Fix/Accept) | A, A2 | C on all sub-points; Fix amended (commit on local confirm) | full |
| H02 | B | C | full |
| H03 a–f | F | C overall; a = PC; b–f = C | full |
| H04 | D | C (with corrections) | full |
| H05 | E | C | full |
| M01 | B | C (practical rate low) | full |
| M02 | C | C (severity Low–Medium) | full |
| M03 | B | C | full |
| M04 | G | C (known/deferred, PLAN Aşama 5) | full |
| M05 | A | C | full |
| M06 | D | C | full |
| M07 | E (measurement), H (CI, keep list, acceptance) | PC / PC | full ("new logic tests" bullet covered by H correction 2 and A/B/C items) |
| L01 | H | C | full |
| L02 | H | PC | full |
| L03 | C (host), G (input), H (client) | PC / PC / PC | full |
| **A1** | B (client), C (host MediaOwner), D (DisplayOwner) | PC / PC / PC | **partial: host SessionOwner not verdicted. Verified in §3.** |
| **A2** | C (latest-frame, HEVC queue, native capture/encode), H (notes, fixtures, state machines, fuzz, plus private-API isolation as an "adjacent bullet") | C / C | **partial: (i) "reliable ordered control + input model protecting key/button/up/modifier edges", (ii) "native *decode* + SurfaceView, no WebView/canvas", (iii) "P-256/HKDF/AES-GCM + pair-key + video proof" have no A2 entry ((iii) is covered in substance by A/SE1). Verified in §3.** |
| A3 | F | C | full |
| A4 | F | C | full |
| A5 | G | AA (pen) / not done (mouse) | full |
| A6 | D | PC | full |
| D1 | D | C | full |
| D2 | A | PC (commit point) | full |
| **D3** | B (client parts) | C | **partial: host part (deterministic M02 race test, then a narrow fix) has no D3 entry. Covered in substance by C M02/X5 (C, item M02-H).** |
| D4 | D | PC | full |
| D5 | E | proposal, partly AA | full |
| D6 | F | C (gap) | full |
| D7 | G | partly AA | full |
| D8 | H | AA (mostly) | full |
| D9 | A (security), H (README, build ID, reset) | C / C. Setup/runbook part via D M06/P-7. | full |
| D10 | H | NV, missing evidence | full |
| X1 | A | C | full |
| X2 | G | AA partly / NV | full |
| X3 | B | gap C | full |
| X4 | B | gap C | full |
| X5 | C | gap C | full |
| X6 | B | NV | full |
| X7 | D | C as a row; host-sleep part NV | full |
| X8 | F | NV | full |
| X9 | G | NV | full |
| X10 | G | AA mostly | full |
| X11 | H (+C PF6-M) | C (gap) | full |
| X12 | E | PC | full |
| X13 | D | C as missing / NV | full |
| B1 | E | proposal / NV (likely too tight) | full |
| F1 | G (input), H | C / C | full |
| **F2** | A (trust), B (video health + decoder), D (display) | C / C+PC / C | **partial: encoder resource-ownership part has no F2 entry. Covered in substance by C M02/SE7.** |
| F3 | H | PC (owner split deferred to the A1 entries) | full |
| F4 | H | C | full |
| F5 | H, D (second access) | C / C | full |

---

## 3. My verdicts for the gaps

### PF5 (GPU-load / Game-60 part): 120 fps app rendering on a 60 Hz panel; encode decimation doesn't recover it; Game 60 helps (Mac GPU 90%→54%)
- Verdict: **CONFIRMED and ALREADY ADDRESSED for games. A residual remains for non-game 120 modes.**
- Evidence:
  - The virtual display refresh follows the stream fps: `host-mac/Sources/MateBridgeCore/Video/StreamPrefsPolicy.swift:49` sets `displayRefreshHz = fps >= 120 ? fps : defaultRefreshHz(60)`.
  - Oyun 60 = 60 fps / 1000‰ (`client-android/.../stream/StreamMode.kt:18`, decision 0016).
  - Device numbers: Oyun 120 has Mac GPU 90% and game CPU 234%; Oyun 60 has 54% and 158%. The note concludes: "Host'un yakalamayı 60'a indirmesi gereksiz… Asıl maliyet oyunun 120 Hz sanal ekranda 120 çizmesi" (NOTES.md:1092-1098).
  - The DISPLAY_RATE feedback thins only the host's capture/encode fps when the panel is at 60 (NOTES.md:1076). The virtual display stays at 120 Hz.
- Residual the review hints at but no report states: in **Akıcı/Performans** (120 Hz virtual display), keyboard-only work drops the panel to 60 Hz (NOTES.md:1076; PF3). Mac apps then still render at 120 while only ~60 are shown.
  - Decision 0016 deliberately forbids automatic mode switching, because a 60↔120 change recreates the display (D/Q3).
  - So the only lever is the user picking Netlik 60 or Oyun 60 for keyboard work.
- Severity: Low (energy/thermal, not correctness). If wanted, document it in the mode descriptions. No card is needed unless the user asks for an energy profile (D8).

### PF7 (client decoder part): verify at startup that the hardware decoder was actually selected
- Verdict: **PARTIALLY CORRECT.**
- Evidence:
  - `VideoRenderer.kt:294` `MediaCodec.createDecoderByType(mime)` takes the platform default.
  - The decoder name is logged on every start: `ev=codec_start name=${codec.name}` (`VideoRenderer.kt:322-323`), and `codecInfo` is shown at `:311`. Device logs show `OMX.hisi.video.decoder.hevc` (NOTES.md:95, 517), so selection can be checked from logs today.
  - No `MediaCodecInfo.isHardwareAccelerated`/`isSoftwareOnly` (API 29+) check exists anywhere in `client-android/app/src/main` (grep empty). Nothing warns if a software decoder (e.g. `c2.android.hevc.decoder`) is picked.
  - The host half is read back but buried (C/PF7).
- Severity: Low. Fold `is_hw=`/`sw_only=` plus a warning line into whichever client stats card lands first (E W1 or H BUILDID-C), mirroring C's PF7-H.

### SE3 (host half): input silence, pen watchdog, disconnect release paths
- Verdict: **CONFIRMED.**
- Evidence:
  - Heartbeat silence: `releaseSilenceUs = 1_500_000` and `closeSilenceUs = 5_000_000` (`host-mac/Sources/MateBridgeCore/Session/SessionMachine.swift:84-85`). At 1.5 s it emits `.releaseInput(id, .silence)` once per connection, plus `heartbeat_silence` (`:516-521`); the latch is reset at `:283` and `:730`.
  - Input watchdog timer (500 ms) on the input queue: `InputController.swift:79-83`.
  - `sessionEnded()` "always releases, even if releaseInput was somehow not called" (`InputController.swift:148-154`).
  - Owed releases never drop (`MateBridgeCore/Input/OwedRelease.swift:1-21`).
- Corrections:
  - Key auto-repeat is not covered by any watchdog (G additional issue 1). This is the one real gap on the host side of SE3.
  - The kernel-buffered stale-input window between 1.5 s and 5 s (G additional issue 2) is the other.

### A1 (host SessionOwner)
- Verdict: **CONFIRMED that it already exists.**
- Evidence: the pure host session owner is `MateBridgeCore/Session/SessionMachine.swift`: connection table, phases, `.proving` takeover, silence release (`:84-85`, `:516-521`, `:607-690`). `SessionServer.swift` drives it on one serial queue (D/W4: `SessionServer.swift:210`).
- Gap: A's additional issue A1 (a non-takeover PAIRED connection is activated before proof). That is a SessionOwner contract hole, not a missing owner.

### A2 (remaining bullets)
- **(i) Reliable, ordered control + input model protecting edges: CONFIRMED.**
  - Control is one TCP connection (PROTOCOL §3).
  - `InputOutbox` holds and merges only `mergeable` kinds while congested (`client/input/InputOutbox.kt:15-16, 37, 103`). Releases, modifier transitions and stroke boundaries are never merged (F/IN11; PROTOCOL.md:555-563).
  - On the host: `OwedRelease` (`OwedRelease.swift:1-21`), the release-all order (`InputStateMachine.swift:247-275`) and the STROKE_START latch (G/IN6).
  - Caveat: the kernel-buffered input age is unbounded (F/IN11, G/M04).
- **(ii) Native decode + SurfaceView, no WebView/canvas: CONFIRMED.**
  - `codec.configure(format, surface, null, 0)` at `VideoRenderer.kt:305`.
  - `SurfaceView` in `res/layout/activity_main.xml:8,14`.
  - No WebView in `client-android/app/src/main`.
  - The GL path is optional/experimental (H/L02 proposes retiring it).
- **(iii) P-256/HKDF/AES-GCM + pair-key protection + video proof: CONFIRMED** (A/SE1 evidence), with the review's own condition "fix the trust workflow" = H01. A2-adversarial also found that a migration candidate is promoted on a **plaintext** PAIRED ack (`SessionMachine.kt:463, 492-511`). The WI-1 fix should gate promotion on the first authenticated host record. **Verifier A's WI-1 does not include this yet.**
- **Private-API isolation: CONFIRMED** (H; D/M06: `CGVirtualDisplay` is only in `VirtualDisplay.swift`, the gesture type only in `MagnifyGestureEvent.swift`).

### D3 (host part) and F2 (encoder ownership part)
- Verdict: **CONFIRMED by reference.** C/M02, X5 and SE7 establish that encoder submit/stop are not serialized (six submit threads, `HEVCEncoder.swift:495-565, 659-679`), and C's item M02-H is the "deterministic race test then narrow fix" D3 asks for.
- Correction carried over from C: the severity is Low–Medium. The session is ARC-retained, so there is no use-after-free. Submit-order inversion in steady state is the more real effect.

### p11 priority statement
Text: "H03 especially high when Wi-Fi is primary; USB-heavy drawing reduces it. H04 may be lower if the tablet is an auxiliary screen, higher for the main-screen goal. For R-tagged findings, first complete the evidence with a deterministic failure scenario. High ≠ only security."
- Verdict: **CONFIRMED (all four parts).**
- H03 context:
  - USB srtt 4.7 ms, send queue 0 (NOTES.md:637).
  - The user draws and games over USB (PLAN.md:181).
  - Wi-Fi was "fine for now" per the T-127 card.
  - So H03 is High only if Wi-Fi becomes primary. F agrees.
- H04 context: the user's stated goal is the tablet as **sole** main screen (NOTES.md:31), so the higher reading applies. D agrees: "High for the stated product goal".
- R-tag rule:
  - M01: B P2 barrier test. M02: C M02-H barrier test. M03: B P3 fake-codec test. All are deterministic, but they **require test seams first** (H TESTSEAM-1; `Package.swift:18` has a single Core test target; `VideoRenderer` calls MediaCodec directly). That should go into those cards' acceptance criteria up front.
  - M06's R part cannot be made deterministic in code; it is a rehearsal (D P-3/P-7).
  - L03: measure first (C, G, H).

---

## 4. Cross-report consistency

### 4.1 Factual contradictions (with resolution)

**K1. Decision number collision.**
- Fact: `docs/decisions/` ends at **0017** (`0017-drawing-mode.md`, withdrawn), so exactly one draft can be 0018.
- Claims of **0018**:
  - A WI-0: tablet trust confirmation;
  - D P-1: virtual-display lifetime;
  - F F-0: Wi-Fi congestion control;
  - G P-M04c: Wi-Fi pen playout;
  - H CI-1: GitHub Actions.
- Claims of **0019**: G P-M04d (stale-input policy) and H KNOB-0 (experiment knobs).
- Unnumbered decision drafts:
  - B P1 (video-health input gate);
  - C LM4-D and E W4 (the same capture-timestamp decision);
  - E W3 (host PING, "short, recommended");
  - E W5 (latency budgets, after measurement);
  - A WI-5 (USB-only profile) and A WI-6 (amends 0015);
  - D P-8 (LaunchAgent) and D P-9 (fallback);
  - F F-7 (extends 0013);
  - G P-KR (amends 0003) and G P-PALM (amends 0006).
- Resolution: the orchestrator assigns numbers at creation time, in D-order. Suggested:
  - 0018 tablet trust (D2);
  - 0019 video-health input gate (D3);
  - 0020 virtual-display lifetime (D4; finalize after D P-3);
  - 0021 latency-metric/capture-timestamp semantics (D5; merged C+E);
  - CI and the experiment-knob policy can take the next numbers whenever they are scheduled. H suggests CI before the race tests.
  - Wi-Fi congestion, pen playout and stale-input come after T-127 and P-M04a data.
- Card drafts should reference decisions by topic, not number.

**K2. LM7: E "CONFIRMED" vs F "PARTIALLY CORRECT".**
- E: "after BSD sockets [Wi-Fi] carries ~60 Mbps … a 432 KB IDR ≈ 58 ms at 60 Mbps".
- F: the 30 Mbit/s is the encoder's average target, the raw single-flow link is ~410 Mbit/s, and the delay is AP/driver queueing.
- Facts:
  - NOTES.md:603-610 gives the raw link at **410 Mbps** down/up per flow (250 KB/33 ms bursts, `sendall` p50 0.3 ms, no loss).
  - NOTES.md:637-641: "`bsd` 60 Mbps'i yeniden gönderimsiz taşıyor". That is the *stream* bitrate carried, not the link capacity.
- **F is right.** E's 58 ms/128 ms serialization estimates use the encoder rate as if it were the link rate.
- Both agree the arithmetic holds and the example is illustrative (the PDF says it was not measured).

**K3. "Physical 1920×1080 monitor" as a rollback path: H/S3 vs D/H04-Q5.**
- H/S3 cites `PLAN.md:9` ("Şu an 1920×1080 bir monitör bağlı") as a physical monitor rollback.
- D says the 1920×1080 display is the headless placeholder, and whether an HDMI dummy is plugged in is unknown.
- Fact: NOTES.md:160 (2026-09-30, later than PLAN's 2026-09-29) says the 1920×1080 display (`v0x756e6b6e/m0x76697274`) "fiziksel monitör değil, başsız Mac'in yedek ekranı". NOTES.md:31 records only the *intention* to keep an HDMI dummy. PLAN.md:9 is stale (H itself flags PLAN staleness in P1).
- **D is right.** The S3 "rollback exists in practice" claim is overstated. The second access path is Parsec only, and it needs D P-7's question to the user (is the HDMI dummy plugged in? Is FileVault on?).

**K4. Wi-Fi TOS/`wifi_ll` knobs: H "retire" vs F "re-measure in T-127".**
- H #15 / KNOB-0 / KNOB-C1 deletes `WifiKnobs.kt`, `WifiKnobsTest` and WAKE_LOCK, because "DSCP and `wifi_ll` had no effect (NOTES.md:597)".
- F needs `--ei tos_ctl 0xB8 --ez wifi_ll true` in the re-scoped T-127 matrix, and F-5 adds `ctl_lowat_kb` *to* `WifiKnobs.kt`.
- Fact: the "no effect" rows (NOTES.md:588-597) were measured on the `nw` stack while the link was saturated at the 27–28 Mbps ceiling (350–390 ms latency), so no QoS marking could show an effect. T-124 later showed that host service-class marking *does* help under `bsd` (NOTES.md:958). Host `SERVICE_CLASS` marks only the Mac→tablet direction (`TransportKnobs.swift:21-58`); the tablet uplink is unmarked.
- **F is right.** Keep these knobs as debug-only until T-127 reports. KNOB-C1 must not delete `WifiKnobs.kt`.

### 4.2 Translation-artifact "corrections"
These come from claims.md wording, not from the review. When reporting to the user, don't present them as review errors. Each underlying code fact is still correct and useful.
- C on LM4 ("not older"), see T5.
- G on IN10 ("not a control interval"), see T3.
- B on V8 ("not async"), see T4.
- E on PF1 ("received, not captured" attributed to the review), see T1.

### 4.3 Duplicate work items (merge before carding)

| Topic | Items | Conflict inside the duplicate | Recommendation |
|---|---|---|---|
| Host PING + input-age meter | E W3, G P-M04b | Both touch Core `SessionMachine.swift`, `SessionServer.swift` and `InputController.swift`. E says "short decision recommended"; G says "no decision, one PROTOCOL sentence". Log formats differ: E has a 10 s per-class window; G has 1 s plus `late_250ms`. | One card. Fact: `docs/PROTOCOL.md:567` already says "Host da aynı aralıkla gönderebilir", and there is no wire or dependency change, so a decision record is **not required** by AGENTS.md. A one-line §6 clarification by the orchestrator is enough. Pick one log shape. |
| Capture-timestamp (6.6 ms PTS lead) decision | C LM4-D, E W4 | C: decide now, option A, `depends_on: []`. E: decide after W2's joined traces (`pts_vs_deliv` variance); option B is a wire change. | One decision card, after E W2. Both agree on the fact (the client under-reports by ~6.6 ms; NOTES l.401) and on correcting PROTOCOL §0x22/§6 "gösterim" text now (doc-only). |
| Per-message injection timing | F F-6, G P-L03i | Same file (`InputController.swift`), overlapping fields in `input_session_end`. | One card. Time `environment()` and `post` separately, plus a >20 ms warning. |
| Device measurement kit / soak | E W6 (`tools/measure/`, `scripts/device-smoke.sh`), H SOAK-1 (`tools/soak/`) | Both recreate `mbmon.sh`/`macmon.sh`, in different directories. | One card, one directory. H already says "merge them there". |
| Lifecycle test seams | H TESTSEAM-1 (`EncoderLifecycle.swift`, `DecoderBackend.kt`), C M02-H (`EncoderSubmitOrder.swift` + `CompressionBackend`), B P3/P1 (`DecoderCodec` interface, `CodecGeneration.kt`) | Three names for the same seams. | Fold the host seam into C M02-H and the client seam into B P3. Make P3's interface a prerequisite of P1's fault injection. Drop TESTSEAM-1 as a separate card, or keep it as the first step of each. |

Near-duplicates to coordinate:
- D P-7 runbook (`docs/RECOVERY.md`) vs H DOC-1 README "short recovery list". H says the runbook is separate, so this is consistent; just link them.
- D/D1 vs H BUILDID-C/H. D defers build identity to L01. Consistent.

### 4.4 Severity disagreement
- **W4 "Mac input":** F says Low–Medium; G says Low.
  - F adds facts G missed: `drainAudio` and the 100 ms tick run on the same session queue (`SessionServer.swift:783-815`; `SessionMachine.swift:514-521`). So a slow `CGEventPost` hurts the audio downlink first, and a >1.5 s block can cause a false silence release.
  - Both say "measure first" (F F-6 = G P-L03i). Not a factual conflict; take F's impact list.
- **M02:** C rates it Low–Medium, against the review's Medium. No other report disagrees.

### 4.5 Ordering conflicts between proposed items
These are not contradictions, but the cards will collide if run in parallel.
- **`host-mac/Sources/MateBridgeHost/Video/HEVCEncoder.swift`** is edited by C M02-H, L03-H and PF7-H; F F-1 and F-4; H KNOB-H1 (removes idle refresh/QP boost) and TESTSEAM-1; E W2 (trace fields).
  - Order: KNOB-H1 (shrinks the surface), then M02-H (owner queue), then F-1 (setter must go through the owner, as F notes), then the rest.
- **`client/video/VideoRenderer.kt` / `MainActivity.kt`:**
  - VideoRenderer.kt: B P1, P2, P3; E W1; H KNOB-C1, KNOB-C2, TESTSEAM-1.
  - MainActivity.kt: those, plus A WI-2/WI-6, E W7, F F-5 and H BUILDID-C/KNOB-C3/RESET-C.
  - Specific clashes:
    - B P3's acceptance includes "GL↔surface fallback" churn, but H KNOB-C2 deletes the GL path.
    - E W1 renames `shown=`→`released=` and `latency_us`→`cap_dec_*` (aliases kept for one release), but H KNOB-C1's acceptance compares "`latency_us` and `shown`" to NOTES and requires `tools/pacing` field names unchanged. Land KNOB-C1 first, or update its criteria.
- **Host `MateBridgeCore/Session/SessionMachine.swift`:** A WI-3 (`.proving` for every PAIRED) and E W3/G P-M04b (host PING/PONG). Do WI-3 first. It is security, and the PING card must then start pinging only after activation.
- **`SessionServer.swift`:** A WI-5 (USB-only bind; its plan hints still reference the `nw` listeners at :600/:987), H KNOB-H1 (removes `nw`), F F-3, E W3/G P-M04b, G P-KR. Do KNOB-H1 before WI-5.
- **`client/session/WifiKnobs.kt`:** F F-5 adds to it; H KNOB-C1 deletes it (K4).
- **`docs/PROTOCOL.md` prose** (orchestrator): A WI-0 (§3 step 3, §9), A WI-3 (§3), F F-0 (§0x03 bitrate = ceiling), E/C (§0x22, §6 latency text), G P-M04d (§4 "Kabul edilen davranış" bound), G P-KR (§4 KEY), E W3/G (§6 host PING). Batch them into one or two orchestrator doc commits.

### 4.6 ID collisions in the reports (rename when carding)
Report-local labels reuse claim IDs:
- A's additional issues are "A1–A7". A1 = pre-proof PAIRED activation, which A2-adversarial also calls "A1"; this collides with claim A1 (three owners).
- F's additional issues are "A-1…A-5".
- E's work items are "W1–W7", colliding with claim W1–W4.
- B's are "P1–P4", D's "P-1…P-9" and G's "P-M04a…", colliding with claim P1–P5.

Prefix them by verifier (e.g. `A:issue-1`, `E:WI-1`) in the merged plan.

### 4.7 Smaller cross-report notes (no conflict, but should travel with the cards)
- A2-adversarial narrows A's "auto-connect without user action": it happens only on the Wi-Fi path while Searching/Disconnected (`MainActivity.kt:1513-1543, 1803-1809`). A2 adds the plaintext-ack migration-promotion hole. **Add it to A's WI-1 acceptance criteria.**
- B (`VideoRenderer.kt:328`) and H (`:327`) cite the unbounded `previous.join()` one line apart. The actual line is **328**.
- B's "host configId always restarts at 1" is correct: `StreamCoordinator.swift:14` (`configID: UInt16 = 1`) and `:202`.
- F's and H's service-class statements agree: the default is `signaling` = control AC_VO, video AC_VI (`TransportKnobs.swift:21-58`).
