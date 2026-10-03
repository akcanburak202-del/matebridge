# Card QA 4: T-189 … T-203 (HEAD 84c0c4c)

Totals: blocker 1, should-fix 15, nit 23. OK: T-193, T-200.

Notes on the checks:
- I spot-checked the cited file:line facts in every card against HEAD. Apart from the items below, they hold, including BsdTcpSocket BindAddress, SessionServer :639/:1031/:1062/:1079/:1636, classify, the main.swift menu and signal lines, DavHandler dispatch/ALLOW, Settings keys, SendQueue, QuickAck, SocketVideoTransport gate, TcpInfoLog, VideoPipeline teardown/fail, StreamCoordinator.onPipelineFailed, SharpnessBench Page/toYCbCr, TouchTracker constants, bundle-host.sh and the PROTOCOL :154/:298/:300/:325/:374/:422/:597 lines.
- Every Plan section is still the placeholder.
- Every gated card (T-195…T-203) states its gate in **bold** in *Amaç*. The gate problems are listed per card below.

## T-189
1. **should-fix**: the dependency on T-186 parks this card behind a long, decision-gated chain, although `nw` is already debug-only.
   - The chain: T-186 ← T-182 (decision 0026, including the user's confirmation that `nw` is retired), T-177 ← T-162/T-176, and T-171.
   - `bsd` is already the default on both sockets (`SessionServer.swift:178, 316-317`), so `nw` is debug-only.
   - **Fix:** add to the Plan hints: "If T-186 has not merged when 0027 is accepted, 'Yalnız USB' forces the `bsd` listeners (it ignores `MATEBRIDGE_CONTROL_SOCKET/VIDEO_SOCKET=nw` and logs that once) instead of waiting. The orchestrator then drops T-186 from `depends_on` and keeps it as serialize-with on `SessionServer.swift`."
2. **nit**: Bonjour has three start paths. `startBonjour` is called at `:1062`, from `republishTxt` (`:579`, the T-128 `wol=` update) and from the retry in `bonjourFailed` (`:1114`).
   - **Fix:** add the hint "Gate inside `startBonjour(for:)` itself, so that neither the TXT republish nor the retry can advertise in USB-only mode."
3. **nit**: two criteria have no tag: the menu toggle criterion and the "switching the mode" criterion.
   - **Fix:** tag both `[device]`. Add "[XCTest] the pure switch decision: no live session → restart now; live USB session → deferred, never cut; live Wi-Fi session → as decided in Plan."

## T-190
1. **blocker**: `client-android/app/src/test/kotlin/dev/matebridge/client/settings/SettingsCatalogTest.kt` is not in `files:`, but the change cannot pass check.sh without editing it.
   - Its fake implements `SettingsHost` (`:42-44`), so new members fail to compile.
   - It asserts that "Tablet dosyaları" has exactly `["files","files_status"]` (`:174`).
   - It asserts the full key list (`:69`).
   - The "[JVM] Settings … persist" criterion also has no natural home: only `test/.../files/` is listed.
   - **Fix:** add these to `files:`:
     - `client-android/app/src/test/kotlin/dev/matebridge/client/settings/SettingsCatalogTest.kt`
     - `client-android/app/src/test/kotlin/dev/matebridge/client/session/FilesScopeSettingsTest.kt` *(new)*
   - Add the criterion "[JVM] SettingsCatalogTest: the Tablet dosyaları section lists `files`, the folder choice, read-only and `files_status`."
2. **should-fix**: limiting `Allow` alone may not give a read-only Finder mount.
   - OPTIONS always answers `DAV: 1, 2` (`DavHandler.kt:86`).
   - macOS webdavfs mounts a volume read-only only when the server lacks class-2 locking. With `Allow` limited but `DAV: 1, 2`, Finder may still mount read-write, and every write fails with a generic error.
   - **Fix:** in Plan hints and the read-only criterion, write "In read-only mode OPTIONS answers `DAV: 1` (no class 2) and an `Allow` with read methods only. [device] Finder shows the volume as read-only."
3. **should-fix**: the link to T-191 only works in one direction, so new keys can escape the reset.
   - T-191 adds T-190's keys to `resetToDefaults()` only "if T-190 merged first".
   - T-190 has no matching instruction for the opposite order.
   - **Fix:** add the Plan hint "If T-191 has merged, add the folder and read-only keys to `Settings.resetToDefaults()` and to `SettingsResetTest`." Add `client-android/app/src/test/kotlin/dev/matebridge/client/settings/SettingsResetTest.kt` to `files:`.
4. **nit**: "PROPFIND of `/`" points at the wrong path. Storage is served under `/MatePad/` (`DavHandler.kt:88-89`, `MOUNT` `:654`), and `/` is the virtual root.
   - **Fix:** write "PROPFIND of `/MatePad/` lists only the chosen folder's entries."
5. **nit**: the criteria take the §5 Q7 answers for granted ("Tüm depolama" is kept, read-only is offered). Decision 0028 leaves both open.
   - **Fix:** prefix the read-only and "Tüm depolama" criteria with "(if decision 0028 keeps it)".
6. **nit**: the card places itself in the `MainActivity.kt` chain "between T-153 and T-159". Neither manifest §2 nor T-159 lists T-190 in that chain.
   - **Fix (orchestrator):** add T-190 to the manifest chains for `MainActivity.kt`, `SettingsCatalog.kt` and `Settings.kt`.

## T-191
1. **should-fix**: clearing SharedPreferences does not reset learned audio state within the same activity.
   - `OutBufMemory` caches stored values in memory (`OutBufMemory.kt:23, 42-48`).
   - `AudioPlayout` owns its memories (`AudioPlayout.kt:86-88`) and is created once per activity (`MainActivity.kt:491`).
   - A live stream re-saves safety about once per second (`SafetyMemory.onSafety`).
   - So after a SharedPreferences-only clear, the next session in the same activity still logs `buf_source=stored`, and the [device] criterion fails.
   - **Fix:**
     - Add `.../audio/OutBufMemory.kt`, `.../audio/SafetyMemory.kt` and `.../audio/AudioPlayout.kt` to `files:`.
     - Add the hint "`AudioPlayout.forgetLearned()` clears both memories' caches and their stores. If a stream is live, the clear is applied at the next stream start (a pending flag), so the running writer cannot store the old value again."
     - Add the criterion "[JVM] after the clear, the same `OutBufMemory` instance returns `SOURCE_DEFAULT`."
2. **should-fix**: the "[JVM] audio store `clear()`" criterion cannot be met as written.
   - `SharedPrefsOutBufStore` and `SharedPrefsSafetyStore` are Android-only, and the project has no Robolectric.
   - Adding `clear()` to `OutBufStore`/`SafetyStore` breaks the fakes outside `files:`: `OutBufMemoryTest.kt:10,109`, `SafetyMemoryTest.kt:11,139` and `SafetyTransportTest.kt:13`.
   - **Fix:** write "Add `clear()` to the store interfaces with a default body, or only to the memories. Test it through the memories with a map store in `SettingsResetTest`. The SharedPrefs implementations are covered by the [device] step."
3. **nit**: the hint "…or a confirm dialog" conflicts with the JVM criterion "needs two steps; one tap alone resets nothing", because a dialog is not JVM-testable.
   - **Fix:** remove "or a confirm dialog", or require that the arming state is a pure helper tested in `SettingsCatalogTest`.
4. **nit**: `depends_on: [T-185]` exists only to serialize `MainActivity.kt`, and T-185 is gated by 0026.
   - **Fix:** add "If T-185 is closed as won't-do, drop it from `depends_on`."
5. **nit**: "Exactly one `ev=settings_reset` line" has no tag.
   - **Fix:** tag it `[device]` (logcat).

## T-192
1. **should-fix**: both dependencies are decision-gated. T-167 waits on 0020. T-189 waits on 0027 §5 Q6, and the user may not want the mode at all. If either is rejected, this card never starts.
   - **Fix:** add "If T-167 or T-189 is closed as won't-do, remove it from `depends_on` and drop its key from the reset list. The card is otherwise independent."
2. **should-fix**: the device precondition may prove nothing.
   - The log line is `from_stored=\(settings != base)` (`StreamCoordinator.swift:325`).
   - Netlik (60 fps, scale 1000, `StreamMode.kt:11`) can equal the HELLO base, so `false` would be logged with or without a reset.
   - **Fix:** write "Precondition: the session before the reset logs `stream_session … from_stored=true`. Use Akıcı/Performans or a non-default bitrate if Netlik gives false. After the reset and a reconnect, the first session logs `from_stored=false`, …"
3. **nit**: "`UserDefaultsStreamPrefsStore.removeAll()` removes the key" cannot be tested, because `MateBridgeHost` has no test target. The menu criterion also has no tag.
   - **Fix:** tag both `[device]`. For the first, write "`defaults read dev.matebridge.host streamPrefsByDevice` reports the key as missing after the reset."

## T-193
OK.

## T-194
1. **nit**: step 1 relies on the `ev=profile` lines from T-185/T-186. Those cards are not in `depends_on` and are 0026-gated.
   - **Fix:** write "…(the `ev=profile` lines from T-185/T-186 if they have merged; otherwise list both sides' launch extras and `MATEBRIDGE_*` environment)".
2. **nit**: step 7 says `tools/soak/summarize.py` prints pass/fail against the thresholds. T-173 only promises trends and slopes (T-173 Kabul).
   - **Fix:** write "`summarize.py` prints the slopes and counts; the orchestrator compares them with step 2's thresholds in NOTES."

## T-195 (gate checked against T-127)
1. **should-fix**: the gate uses a clause that T-127 never records, and it differs from T-196's gate for the same branch.
   - The clause is "with static text the user still accepts". T-127's procedure and Kabul collect no static-text verdict.
   - T-196 restates the same branch without that clause.
   - T-127 itself never defines the rule for choosing "go adaptive", so two cards define the gate in two ways.
   - **Fix (T-195 *Amaç*):** "**Gated: start only after T-127's NOTES entry records decision 0023 branch 'go adaptive' (rule in T-127). If it records 'fixed profile suffices', close as won't-do; T-178 is the answer.**"
   - **Fix (orchestrator, T-127 Kabul):** "'go adaptive' iff in topology 3 no bitrate row (default/30/15 Mbps) meets all three budgets, or the user rejects static text at the lowest row that does. The user's static-text verdict per row is recorded."
2. **should-fix**: the golden replay needs a trace that nobody is asked to produce.
   - T-127 writes only per-run percentiles to NOTES, and raw logs are never committed (AGENTS privacy).
   - The implementer has no device.
   - `ev=tcp` is a 1 s window (`SessionServer.swift:312`) with no per-frame bytes.
   - **Fix:** extend the gate: "…and the orchestrator has extracted one numbers-only topology-3 trace (per second: `ev=tcp` srtt/sbbytes/retx and the video bytes from `net ev=stats`) into this card's *Bağlam*."
   - Add to the replay criterion: "the replay runs at 1 s resolution; sub-second behaviour is covered by the synthetic tests."

## T-196 (gates checked against T-127, T-195 and T-177)
Gate (3) matches T-177's [device] criterion: 60→15→60 within ≤1 s, no reconnect.
1. **nit**: gate (1) restates the T-127 rule without T-195's static-text clause.
   - **Fix:** write "(1) T-127's NOTES entry records 'go adaptive' (rule in T-127)", to match T-195 #1.
2. **nit**: "[XCTest] fake socket" has no seam to work against. `SocketVideoTransport` holds a concrete `BsdTcpConnection` (`SocketVideoTransport.swift:36, 42`).
   - **Fix:** add the hint "Seam: keep the admission decision pure (next to `SocketVideoGate.canSend`, `:3`) and inject a TCP-snapshot provider closure; or use loopback `BsdTcpConnection` pairs as `BsdTcpSocketTests` does."
3. **nit**: `docs/LOGGING.md` is in `files:`, but the criterion says the entry is only "proposed".
   - **Fix:** write "the `video ev=adapt` entry is added to `docs/LOGGING.md`."

## T-197 (gate checked against T-127, T-179 and T-171)
1. **should-fix**: no gating card produces the data this gate needs.
   - T-127 step 6 records neither T-171 `ev=input_age` nor the client `MB/input merged=` (`Model.kt:201`), and T-127 does not depend on T-171.
   - T-179 records only pen p50/p95/max and `late_250ms`: no pointer data, no p99, no `merged=`.
   - T-127's "whether uplink stalls were seen (input for T-197)" has no defined measurement.
   - **Fix (gate):** "**Gated: start only after a recorded Wi-Fi run that logged, per second, host `ev=input_age` (pen/pointer p99, `late_250ms`) and the client `MB/input merged=` shows uplink stalls. That run is T-127/T-179 if they captured both, or else the knob-off arm of this card's device procedure on the current build (it needs no code). Evidence: in topology 2 or 3, ≥2 of 3 runs, pen/pointer p99 > 100 ms or `late_250ms` > 0, with `merged=` ≈ 0 in the same seconds, and not removed by the `tos_ctl 0xB8` + `wifi_ll` row.**"
2. **nit**: `depends_on` is [T-127, T-171], while manifest §2a says [T-127]. The addition is justified.
   - **Fix (orchestrator):** update the manifest.

## T-198 (gate checked against T-179)
1. **should-fix**: the gate contradicts T-179's decision rule.
   - T-179 says: if clustering persists only in topology 3, "Mac Ethernet is the advice, not playout", which parks T-198.
   - T-198 opens on clustering "in at least one Wi-Fi topology (… or both on Wi-Fi)".
   - **Fix (gate):** "…T-179 has recorded 'kümelenme sürüyor → T-198 açılabilir'. That requires clustering by the rule below in topology 2 (Mac Ethernet + tablet Wi-Fi), or in topology 3 only if the user states that Ethernet is not an option…"
   - **Fix (orchestrator):** copy the numeric rule (median < 1.5 ms or p95 > 8 ms in ≥2 of 3 runs, plus the Krita verdict) into T-179's decision output.
2. **nit**: the new `input_session_end` fields (`playout_*`) need a LOGGING.md entry.
   - **Fix:** add "Propose the `docs/LOGGING.md` fields under *Açık sorular* (orchestrator)."

## T-199 (gate checked against T-171, T-127, T-179 and T-180)
1. **should-fix**: most of the named data sources do not record the fields the gate uses.
   - T-127 records no `ev=input_age`.
   - T-180 has `depends_on: []`, and its "Wi-Fi off mid-stroke" row records only `input_release`/`owed` and the close time.
   - T-171's own device run records p50/p95/p99/max and `offset_rtt_us`, but not `clock_unc_us`.
   - **Fix (gate):** "(1) a recorded Wi-Fi run made with T-171 merged shows `max` > 300 ms in `ev=input_age` for pen, pointer or key, with `clock_unc_us` p95 ≤ 30 ms in the same seconds. That run is T-179, or a dedicated run of this card's device scenario (a ~3 s tablet Wi-Fi toggle while typing and tapping) on the current build…"
2. **should-fix**: POINTER `buttons` is a level mask, not an edge (PROTOCOL `:339`, `:354`), and the card handles stale partial input only for PEN.
   - If a stale down edge is ignored, the next fresh POINTER message with the bit still set becomes a new down edge in the middle of the drag. This is the same partial-stroke problem the card handles for PEN.
   - **Fix (Risks):** "POINTER: a button whose down edge was ignored as stale stays latched as ignored until a message clears the bit, or until release-all. Later fresh messages with the bit set do not press it."
   - **Fix (Kabul):** "[XCTest] a stale button-down followed by fresh POINTER messages with the bit still set never presses; the release clears the latch."
3. **nit**: "age > 300 ms (`max` or `late_250ms` > 0)" mixes thresholds. `late_250ms` counts ages above 250 ms, so a non-zero count does not show an age above 300 ms.
   - **Fix:** write "`max` > T_stale (300 ms); `late_250ms` > 0 alone is not enough."
4. **nit**: the new `input_session_end` counters need a LOGGING.md entry.
   - **Fix:** add "Propose the `docs/LOGGING.md` fields under *Açık sorular*."

## T-200 (gate checked against T-166)
OK.
- The gate matches T-166's step 2 and its Kabul ("T-200 go/no-go … display survives display sleep: yes/no").
- The no-go branch (narrow the card or close it, recorded in the card) is explicit.
- The cited VideoPipeline and StreamCoordinator lines are correct.

## T-201 (gate checked against T-188)
1. **should-fix**: the bench cannot answer the gate's first trigger.
   - The bench decodes on the Mac with `VTDecompressionSession` (`SharpnessBench.swift:16, 178-211`). It measures host encode plus Apple decode only.
   - It cannot settle a tablet-side range question (MediaCodec colour keys, `VideoRenderer.kt:286-288`).
   - The gate's first trigger is "range verdict could not be confirmed from the tablet `screencap`". That is also broader than T-188's own trigger ("T-201 only if the by-eye verdict on coloured text is inconclusive").
   - **Fix (gate):** "**…start only after T-188 records 'T-201 needed' because the fringing on thin coloured text could not be attributed by eye…**"
   - **Fix (Kapsam dışı):** "The verdict covers the host encoder plus VT decode. A tablet-side range or transfer question needs its own card."
2. **nit**: the table criterion and the bitrate hint do not fit together.
   - The criterion asks for "per bitrate (30/60/80) in one numeric table".
   - The hint sets bitrates through the existing env knobs, which allow one bitrate per run (`MATEBRIDGE_BITRATE_KBPS`, `SharpnessBench.swift:14`).
   - An in-process loop would need `SharpnessBenchOptions.swift`, which is not in `files:`.
   - **Fix:** write "one table per run; three runs at 30/60/80 Mbps", or add `host-mac/Sources/MateBridgeCore/Video/SharpnessBenchOptions.swift` to `files:`.
3. **nit**: `depends_on: [T-186]` exists only to serialize `SharpnessBench.swift`, and T-186 is 0026-gated.
   - **Fix:** add "If T-186 is closed as won't-do, drop it from `depends_on`."

## T-202 (gate checked against T-147 and T-148)
Gate OK: T-147 scenario 3 records the crash outcome and the time until the Mac was reachable. §5 Q11 and the deferred decision are named.
1. **nit**: the failure-first criterion accepts the T-147 entry only "if it recorded exactly this", but T-147 scenario 3 uses `kill -9` (T-147 `:36`), not `-SEGV`.
   - **Fix:** write "`kill -SEGV` or `kill -9` (T-147 scenario 3 counts)."
2. **nit**: the plist test omits `Label`, which launchd requires.
   - **Fix:** add `Label` to the asserted keys of the plist template test.
   - **Fix:** add "[device] `open -a MateBridge` while the agent-launched host runs activates it and does not start a second host. A second host would take fallback ports."

## T-203 (gate checked against T-181)
1. **should-fix**: the gate uses per-contact statistics from a different time window than the filter.
   - T-181 reports each contact's max and median size over the whole contact (T-181 step 2).
   - The filter decides within `HOLD_MS` (40 ms) or before slop (16 px). The card's own hint says "max size during HOLD_MS".
   - A palm that grows after 40 ms looks separable in T-181's data but not to the filter.
   - **Fix (gate):** "…(2) the distributions of each contact's max `size`/`touchMajor` within its first 40 ms, or until it moves 16 px, separate: …"
   - **Fix (orchestrator):** add that statistic to T-181 step 2.
2. **nit**: `decisions: []`, although the work is gated on the 0006 amendment (the manifest says "[0006 amend]").
   - **Fix:** set `decisions: [0006]`, so the implementer reads it (AGENTS "Before you write code" step 2).
