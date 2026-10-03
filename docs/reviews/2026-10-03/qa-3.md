# QA-3: T-127, T-176 … T-188

Checked against HEAD 84c0c4c. No code changed since a30c769 (`git diff --stat a30c769 HEAD -- host-mac client-android tools scripts` is empty), so the cited line numbers still apply. Most file:line citations I spot-checked are correct. Every Plan section is the placeholder.

**K4 check (T-182 … T-186 against verify-H #15 and coverage-audit K4):** passes.
- T-182 row 15 classes `tos_ctl`/`tos_video`/`wifi_ll` + WifiLockHolder + WAKE_LOCK as **debug-only until T-127**. verify-H had "retire"; K4 overrides it.
- T-183 has no `WifiKnobs.kt`, `WifiKnobsTest` or `AndroidManifest.xml` in `files:`, and its acceptance asserts they are untouched.
- T-185 only gates these knobs behind `dev`, which matches "debug-only".
- T-186 retires only `nw`, idle refresh, FRAME_DELAY, PRIO_SPEED, H264_PROFILE and INPUT_RETAG. It keeps host `SERVICE_CLASS`, `NOTSENT_LOWAT_KB` and `WIFI_BITRATE_KBPS`.
- None of these cards retires a Wi-Fi knob before T-127. The one interaction problem is in T-127 (issue 1).

---

## T-127
1. **should-fix.** After T-185, the knob row silently stops working. T-185 gates `tos_ctl`/`tos_video`/`wifi_ll` behind `--ez dev true`, and T-185 can land before T-127 runs: T-185's chain does not depend on T-127. T-185 only tells its implementer to "note it for the orchestrator". Without the flag, T-127's row would measure the default and report "no effect" again.
   Fix (Procedure step 5 and the matching acceptance line): "default bitrate with `--ei tos_ctl 0xB8 --ez wifi_ll true` (add `--ez dev true` if T-185 is in the build; check that `ev=dev_knobs ignored=-` and the `ev=net` `tos_ctl=0xb8 wifi_ll=1` fields appear before the run counts)."
2. **should-fix.** The knob row cannot produce the verdict T-182 expects.
   - KNOBS row 15 covers three knobs plus WifiLockHolder/WAKE_LOCK. T-127 measures only `tos_ctl` + `wifi_ll`, and only combined.
   - `tos_video` is never measured, and a combined effect cannot say which knob to keep.
   Fix (step 5, add): "If the combined row beats the default row on control srtt p95 or underruns, run ≥3 runs each of `tos_ctl` only and `wifi_ll` only. `tos_video` (uplink ACKs only) gets one combined run with `--ei tos_video 0x88`, or is recorded as 'not measured → retire with the row verdict'." Acceptance: "…with a keep/retire verdict **per knob** (`tos_ctl`, `tos_video`, `wifi_ll`/WifiLock)".
3. **nit.** The acceptance hands the verdict to `docs/KNOBS.md`, but that file is not in `files:`. Add `docs/KNOBS.md` to `files:`, or reword to "the orchestrator records it in `docs/KNOBS.md` in a separate commit".

## T-176
1. **should-fix.** The device criterion is circular. The card says it "can land before T-127", and T-127 records "whether T-176 is included". If T-176 lands first, no pre-T-176 Wi-Fi baseline exists, so "`idr=` per second is below the T-127 baseline" cannot be checked.
   Fix: "[device] A/B in one session on topology 3 (or 2): the build before T-176 vs this branch, same workload, ≥3 runs each. `idr=`/`idr_bytes_max=` per stats window are lower, `frames_dropped` and decode errors do not rise, and no freeze is longer than 1 s. If T-127 has already run without T-176, compare against its topology-3 row instead."
2. **should-fix.** Policy (a) conflicts with the AGENTS.md hard rule "For video frames the newest frame wins, and stale frames are dropped". (a) keeps `IDR, d1` and refuses every newer delta until a new keyframe arrives. The card offers (a) without flagging the conflict.
   Fix (after the policy list): "(a) keeps older frames over newer ones, which contradicts the AGENTS.md 'newest frame wins' rule. Choose it only with an explicit argument in Handoff (refused deltas are undecodable anyway). The orchestrator must approve that deviation in review. Default: (b)."
3. **should-fix.** The optional pre-encode skip can strand a static screen.
   - SCK delivers no captures while the screen is static (SharpnessBench.swift:15 comment).
   - If the last capture before the content settles is skipped, "the first capture after the queue drains" never comes. HEVCEncoder's `last` still holds the older buffer, so `resubmitLast`/`idleTick` re-encode stale content.

   Fix (append to the optional-skip acceptance item): "A skipped capture still replaces the encoder's `last` buffer (or is submitted once the queue drains), so a screen that goes static during back-pressure converges to the latest content. Test: push N captures while the queue is full, then stop capturing and drain; the last submitted buffer is capture N."
4. **nit.** The skip hook "must go through T-162's owner queue", but `host-mac/Sources/MateBridgeCore/Video/EncoderSubmitOrder.swift` is not in `files:`. Either add it, or say "the skip decision is made in `VideoPipeline` before `encode()`; `EncoderSubmitOrder` is not changed".

## T-177
1. **should-fix.** The cited "live-property precedent" is actually negative. `HEVCEncoder.swift:220-223` (T-087) says the `.fast` profile "accepts a mid-stream MaxAllowedFrameQP and ignores it", and `.fast` is the default at every fps. A setter can return `noErr` and still have no effect. As written, the [device] criterion ("bytes follow within ≤1 s") is a hardware property the implementer cannot make true.
   Fix, in Bağlam: "Caveat: T-087 found `.fast` silently ignores a mid-stream `MaxAllowedFrameQP` (HEVCEncoder.swift:220-223). Expect the same risk for `AverageBitRate`." In acceptance: "…follow each step within ≤1 s, **or** the run records that VT ignores the change. In that case also try `MATEBRIDGE_ENCODER=llrc` at 60 fps and record both. A negative result is a valid outcome. It blocks T-196's encoder half and is written in NOTES."
2. **nit.** "per-second bytes in host `net ev=stats`": the field is `sent_kbps=` (StreamCoordinator.swift:448-451), one line per client STATS interval (1 s). Name it.

## T-178
1. **should-fix.** The default goes missing on a first-ever connection. With no stored prefs, `VideoSettings.initialSettings` returns `defaults` (= `base`) unchanged (`StreamPrefsStore.swift:43-47`). `base.bitrateKbps` is the `tabletDefault` 30 000 (VideoSettings.swift:30-32), and `applying(_:)` is never called. A rule implemented only in `applying`/`defaultBitrateKbps` would leave that session at the USB default.
   Fix (design hints + acceptance): "`applyingTransportKnobs(.network)` also applies the Wi-Fi cap to `self.bitrateKbps` when there is no override. [XCTest] `initialSettings(defaults: base(.network), stored: nil)` yields the Wi-Fi default with `bitrate_source=wifi_default`."
2. **nit.** `bitrate_source=wifi_default` "for every stream mode" is ambiguous when `wifiDefault ≥ modeDefault`, because then the cap does not bind (for example Netlik 60 = 30 Mbps if the Wi-Fi value is ≥ 30). Say whether the label means "Wi-Fi session default rule" (always) or "the cap bound" (`prefs` otherwise).

## T-179
1. **nit.** `depends_on: [T-171, T-127]`, but T-127 step 8 says "optional in the same session: T-179". With a hard dependency, T-179 cannot start until T-127 is done.
   Fix (T-179 Bağlam): "May run in the same device session as T-127 (after T-127's rows are recorded); the dependency only ensures the topology setup and SHAs exist."

## T-180
1. **nit.** Listing the whole `scripts/` directory in `files:` is broader than "a recorder tool". Narrow it to `scripts/pen-recorder*` (or the exact name chosen), or say "new files under `scripts/` only; existing scripts are not edited".

## T-181
OK

## T-182
1. **nit.** `docs/decisions/0026-experiment-knobs.md` already exists as a proposed draft (commit 3e1c3c7). It lacks the jitter buffer 1–2 open point, the per-row file references and the user's answer. The acceptance says it "is written from the draft above".
   Fix: "The existing 0026 draft is updated: add the jitter 1–2 open point, record the user's answers (GL, `nw`, jitter), set status to accepted."

## T-183
1. **should-fix.** A test file is missing from `files:`. `client-android/app/src/test/kotlin/dev/matebridge/client/security/RecordOpenTest.kt:59` calls `Records.bench()`. Deleting the crypto bench (`Records.kt:56-121`) breaks that test, and the acceptance grep ("no test source references … the crypto bench") cannot pass. Add the file to `files:`, with scope "bench test only".
2. **should-fix.** The inflight-limit scope is ambiguous and clashes with "unchanged" tests.
   - The limit logic lives in `InFlightGauge.canQueue` (`video/SlotReleaser.kt:130ff`). `PresentationSchedulingTest.kt:92-135` (`InFlightGaugeTest`) and `:138-145` (`presentFieldsFormat`, which expects `inflight_limit=0`) test it. Neither file is in `files:`, yet the acceptance requires `PresentationSchedulingTest` to pass unchanged.

   Fix: "Remove only the `maxInFlight`/`inflightLimit` plumbing and the VideoRenderer gate (`:447-452`). `InFlightGauge` (occupancy, `in_codec_p95`) and the `inflight_limit=` field of `presentFields` stay (constant 0), so `PresentationSchedulingTest` is unchanged. Deleting `canQueue` is a follow-up." Alternatively, add `SlotReleaser.kt` and `PresentationSchedulingTest.kt` and drop the "unchanged" claim for that test.
3. **nit.** The grep acceptance (`recenter`, cpd) will hit `video/PaceTrace.kt:113` (`PATHS` contains "recenter", "cpd"). Those path codes are the `pace_trace` CSV format that `tools/pacing` reads. Add: "except the `PaceTrace.PATHS` names, which stay so trace path codes keep their index".
4. **nit.** `ev=display_timing` (MainActivity.kt:1282-1288) carries `keep_jitter=`, `recenter=`, `pacer=`, `cpd_q_permille=`, `cpd_hold_us=` and `inflight=`, all of which go. Add: "list the removed `display_timing`/`present` fields under *Açık sorular* for the orchestrator's LOGGING.md edit."

## T-184
OK

## T-185
1. **should-fix.** `ev=profile` "repeats the decoder `is_hw` value". At `installConfig` (MainActivity.kt:1147) the codec is restarted asynchronously (`r.reconfigure(config)`, :1176; `ev=codec_start` is logged later at VideoRenderer.kt:322). So `is_hw` for this config is not known yet, and reading it would need a VideoRenderer accessor. `VideoRenderer.kt` is not in `files:`.
   Fix: either drop `is_hw` from `ev=profile` ("it is in `ev=codec_start` since T-168"), or add `VideoRenderer.kt` to `files:` with "expose the last codec's `is_hw`; `is_hw=-` until the first `codec_start` of this config".

## T-186
1. **blocker.** Socket-knob tests outside `files:` contradict the acceptance.
   - `host-mac/Tests/MateBridgeCoreTests/Session/ControlSocketTests.swift:266-278` (`testControlSocketKnob`) and `host-mac/Tests/MateBridgeCoreTests/Session/SocketWriteBufferTests.swift:159-168` (`testVideoSocketKnob`) assert `ControlSocketKnob`/`VideoSocketKnob` parse `nw` → `.nw`.
   - Removing that parsing (TransportKnobs.swift:79-95, :138-153) breaks both, and neither file is in `files:`.
   - The acceptance still requires "`ControlSocketTests` … pass **unchanged**".

   Fix: add both test files to `files:`, and change the acceptance to "`ControlSocketTests` and `BsdTcpSocketTests` pass; only `testControlSocketKnob` (ControlSocketTests) and `testVideoSocketKnob` (SocketWriteBufferTests) lose their `nw` cases."
2. **should-fix.** `FRAME_DELAY` removal reaches files outside `files:`.
   - `host-mac/Sources/MateBridgeHost/Video/VideoDump.swift:4,14,39-41,55` has a `--frame-delay` option that sets `settings.maxFrameDelayCount`. Removing `maxFrameDelayCount` from VideoSettings breaks the build.
   - `StreamCoordinator.swift:183` names `MATEBRIDGE_FRAME_DELAY` in a comment, so the acceptance grep "no … `FRAME_DELAY` … in Sources" fails.

   Fix: add `VideoDump.swift` (drop `--frame-delay`) to `files:`, and either add StreamCoordinator.swift ("comment line 182-184 only") or exempt comments in the grep criterion.
3. **should-fix.** Internal contradiction: frontmatter `depends_on` includes T-145, but Bağlam says "T-145 (D1) is not in `depends_on`. If it has not merged, stop…". Delete that sentence. Keep "`sha=` from T-145's `BuildInfo`".
4. **should-fix.** The card is too big and couples two hot-file chains.
   - In one context window it covers: removing the `nw` stack from a 1,805-line SessionServer plus TcpSocketProbe; idle refresh and four knobs in the encoder; and a new profile line, across ~20 files.
   - It ties the SessionServer chain (T-171 → T-186 → T-189) to the HEVCEncoder chain (T-177 → T-186 → T-187). As a result, T-189 (USB-only, security) waits for T-177 (H03 bitrate) for no technical reason. The card already speaks of running "this card's encoder part first".

   Fix: split into
   - **T-186a** `nw` sockets: SessionServer, TcpSocketProbe, TransportKnobs and the socket tests; `depends_on [T-182, T-171]`; then T-189.
   - **T-186b** encoder knobs + `ev=profile`: HEVCEncoder, EncoderKnobs, VideoSettings, InputColorTags, benches, VideoDump; `depends_on [T-182, T-177, T-145]`; then T-187, whose `depends_on` becomes T-186b.

## T-187
OK. If T-186 is split, set `depends_on: [T-186b]`.

## T-188
1. **nit.** The Mac `screencapture` PNG is colour-managed too (see the ~33.7 dB note, NOTES.md:562), so it is not a neutral reference for 0/16/235/255. Add to step 5: "The reference values are the page's authored values (0, 16, 235, 255). The Mac screenshot is a sanity check. Judge the range verdict on the tablet screencap against the authored values."

---

**Counts:** blocker 1 · should-fix 13 · nit 11
