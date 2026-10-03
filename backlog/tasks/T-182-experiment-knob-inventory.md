---
id: T-182
title: Record decision 0026 and the knob inventory; close T-019 and T-067
status: review
phase: 6
owner: orchestrator
depends_on: []
decisions: [0026]
files:
  - docs/decisions/0026-experiment-knobs.md
  - docs/KNOBS.md
  - backlog/tasks/T-019-gl-jitter-wifilock.md
  - backlog/tasks/T-067-client-lock-recenter.md
  - backlog/BOARD.md
  - backlog/tasks/T-182-experiment-knob-inventory.md
---

## Amaç

The daily product path carries about 60 experiment switches: 33 client launch extras, 25 host `MATEBRIDGE_*` environment variables and 4 host CLI modes. Many belong to concluded or negative experiments, and some sit in lifecycle-sensitive code (the GL path, the `nw` sockets, idle refresh). Before any code is removed (T-183 … T-186, T-204), this card fixes the classification (keep / debug-only / retire) in one decision and one table, so implementers do not re-argue experiments. It also closes the two parked cards that this classification ends.

Source: external architecture review 2026-10-03 (L02, F3, D8); verification: docs/reviews/2026-10-03/verify-H-hygiene.md (KNOB-0, L02 inventory) and docs/reviews/2026-10-03/verify-F-network.md (T-019 superseded); coverage audit K4 (docs/reviews/2026-10-03/coverage-audit.md).
Decision 0026 must be accepted by the user before work starts. This card writes the decision down; the user must explicitly confirm retiring the GL presentation path and the Network.framework (`nw`) sockets, both of which were informally "kept as an option".

## Bağlam

**Decision 0026 draft (from H KNOB-0, amended by audit K4):**
- Every knob (client launch extra, host `MATEBRIDGE_*` env var, CLI mode) is listed in `docs/KNOBS.md` with its card, default, class (keep / debug-only / retire) and outcome.
- New knobs default to off and name the card that will adopt or retire them. A knob whose experiment has concluded is retired in the closing card or an immediate follow-up.
- Client debug-only extras are honoured only with `--ez dev true` on the same launch (T-185). The daily APK is the **debug** variant (`scripts/install-apk.sh:15`; no `buildTypes`), so a build-type split is not enough.
- `MainActivity` is the exported launcher (`client-android/app/src/main/AndroidManifest.xml:19-28`), so any app on the tablet can pass these extras today.
- Each side logs one `ev=profile` line at session or stream start: the client in T-185, the host in T-204.
- **Retire:** GL presentation (T-018/T-019), `nw` sockets (T-091/T-111), idle refresh (T-086/T-087), perf hint (T-079), refresh vote (T-140), the cpd pacer (T-080), the inflight limit (T-057), oprate (T-052), keep_jitter/recenter (T-067), crypto bench (T-076), `MATEBRIDGE_FRAME_DELAY`, `MATEBRIDGE_PRIO_SPEED`, `MATEBRIDGE_H264_PROFILE`, and `MATEBRIDGE_INPUT_RETAG=0`. T-019 and T-067 close as won't-do.
- **Not retired (audit K4):** the client Wi-Fi knobs `tos_ctl`, `tos_video` and `wifi_ll` (with `WifiLockHolder` and the `WAKE_LOCK` permission) stay **debug-only until T-127 re-measures them under `bsd`**. Their 2026-10-01 "no effect" result (NOTES.md:588-597) was measured on the `nw` stack while the link was saturated at the ~27–28 Mbps ceiling, so no QoS marking could show an effect. T-124 later showed that host service-class marking does help under `bsd` (NOTES.md:958). The tablet uplink is unmarked by default. After T-127, the orchestrator records keep or retire in `docs/KNOBS.md`. T-197 also adds `ctl_lowat_kb` to `WifiKnobs.kt`.
- Draft status "önerildi". The draft already exists in the house decision format (`docs/decisions/0026-experiment-knobs.md`, commit 3e1c3c7). It lacks the jitter buffer 1–2 open point, the per-row file references and the user's answers; this card adds them.

**Full classified inventory at HEAD (a30c769), verified file:line.**

Classes:
- **keep**: a daily feature or a needed diagnostic; stays as is.
- **debug-only**: kept, but honoured only behind `dev` (client) and listed in the profile line.
- **retire**: code removed; the experiment concluded negative or no-effect, or was superseded.

Abbreviations:
- `MA` = `client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt`
- `VR` = `…/client/video/VideoRenderer.kt`
- `HE` = `host-mac/Sources/MateBridgeHost/Video/HEVCEncoder.swift`
- `EK` = `host-mac/Sources/MateBridgeCore/Video/EncoderKnobs.swift`
- `VS` = `host-mac/Sources/MateBridgeCore/Video/VideoSettings.swift`
- `TK` = `host-mac/Sources/MateBridgeCore/Session/TransportKnobs.swift`
- `SS` = `host-mac/Sources/MateBridgeHost/Session/SessionServer.swift`

*Client launch extras (33 keys read by `MainActivity`/`AudioPlayout`; `net_bench` has 4 more sub-keys read by `bench/NetBench.kt`):*

| # | Knob | Where | Card / evidence | Class | Executed by |
|---|---|---|---|---|---|
| 1 | `--ei jitter N` (fixed buffer 0–2 via `FramePacer`) | MA:375-384; VR:368, :532 | T-016/T-052; GameJitter (`stream/GameMode.kt:107-112`) | debug-only. Open point for 0026: also retire the buffer 1–2 branch? If yes, T-183 deletes `FramePacer` but keeps `VsyncClock` (`video/FramePacer.kt:18`) | T-185 (gate); T-183 if 1–2 retired |
| 2 | `--ei hz N` | MA:411 | T-046 | debug-only | T-185 |
| 3 | `--ei oprate 0/-1/-2/N` | MA:373; VR:284; `video/OperatingRate.kt` | T-052; NOTES.md:315 (HiSilicon ignores `KEY_OPERATING_RATE`) | retire the knob. Default behaviour (rate = stream fps) is kept unless T-183 shows it is a no-op | T-183 |
| 4 | `--es render gl`, `--ei frate`, `--ez glpts` (GL path; `video/GlPresenter.kt`, 366 lines; about 50 GL references in MA) | MA:367-369, :440-441; `res/layout/activity_main.xml:15` (`video_gl`) | T-018 done; T-019 blocked/parked; NOTES.md:132-136 | retire (**user confirmation**) | T-184 |
| 5 | `--ez stats_1s true` | MA:371 | T-141 | keep (diagnostic) | — |
| 6 | `--ei inflight N` | MA:385, :1160; VR:447-452 | T-057; NOTES.md:342 | retire | T-183 |
| 7 | `--ei lead_us N` | MA:386-389 | T-057/T-061; NOTES.md:376-381 | debug-only (re-tune after an OS update) | T-185 |
| 8 | `--ei deadline_us N` | MA:391-396 | T-071; NOTES.md:458-466 | debug-only | T-185 |
| 9 | `--ez keep_jitter`, `--ez recenter` | MA:397-398; `video/AdaptivePacer.kt`, `video/FramePacer.kt` (VsyncClock fields) | T-067 blocked (inconclusive) | retire | T-183 |
| 10 | `--es pacer cpd`, `--ei cpd_q_permille`, `--ei cpd_hold_us` | MA:400-405; `video/ConstantPlayoutPacer.kt` (139 lines); VR:377-380, :560 | T-080; NOTES.md:448-453 (user felt the latency) | retire (keep `tools/pacing/sim.py` and `trace7_120hz_excerpt.csv`) | T-183 |
| 11 | `--ez pace_trace true` | MA:406; `video/PaceTrace.kt`; `security/Records.kt:53` (`stampOpens`) | T-069/T-073/T-077 | keep (diagnostic; source of `tools/pacing` replay material) | — |
| 12 | `--ez crypto_bench true` | MA:408-410; `security/Records.kt:56-121` | T-076; NOTES.md:421 | retire | T-183 |
| 13 | `--ez perf_hint`, `--ei perf_hint_target_us` | MA:345-353; `video/PerfHint.kt` (178), `video/AndroidPerfHint.kt`; VR:331-337, :402-407, :473-476 | T-079; NOTES.md:440 (`session=0` on HarmonyOS 4.3) | retire | T-183 |
| 14 | `--ei ping_ms N` | `session/WifiKnobs.kt:30`; MA:310-315 | T-089 | debug-only | T-185 |
| 15 | `--ei tos_ctl`, `--ei tos_video`, `--ez wifi_ll` | `session/WifiKnobs.kt:31-32`; MA:310-338; `AndroidManifest.xml:6-7` (WAKE_LOCK) | T-089; NOTES.md:588-597 (confounded by `nw`) | **debug-only until T-127** (audit K4), then keep or retire | T-185 (gate); T-127 decides |
| 16 | `--ei rvote`, `--ei rvote_min_fps`, `--ei rvote_prio` (hidden-API reflection) | MA:294-308, :431, :1790; `video/RefreshVote.kt:149-150` (186 lines) | T-140; NOTES.md:1083-1086 | retire | T-183 |
| 17 | `--ez audio false` | MA:415 | T-095 | debug-only | T-185 |
| 18 | `--es transport auto/usb/wifi` | MA:417-420 | T-096 | debug-only (useful for USB/Wi-Fi A/B) | T-185 |
| 19 | `--es audio_out aaudio/track/auto` | MA:485; `audio/AudioPlayout.kt:114`; `audio/SinkPolicy.kt:24` | T-100/T-101 | debug-only | T-185 |
| 20 | `--ei audio_buf_bursts N` | `audio/AudioPlayout.kt:94`; `audio/AudioBufferConfig.kt:14` | T-110/T-114 | debug-only. Its growth leaks into saved learned state (T-110 card :127); the reset comes in T-191 | T-185, T-191 |
| 21 | `--ez quickack false` | MA:492-494; `session/QuickAck.kt:31-32` | T-074; NOTES.md:415-418 | debug-only | T-185 |
| 22 | `--ez stall_diag true` | MA:495-496; `diag/StallDetector.kt` | T-120/T-142 | keep (diagnostic, already opt-in) | — |
| 23 | `--es net_bench host:port` (+ `net_bench_s`, `net_bench_dir`, `net_bench_streams`, `net_bench_rcvbuf_kb`) | MA:358-365; `bench/NetBench.kt:39-59`; `bench/*` (322 lines); `AndroidManifest.xml:29-34` | T-090 | debug-only; move to the `src/debug` source set | T-185 |

*Host runtime environment variables (25):*

| # | Knob | Where | Card / evidence | Class | Executed by |
|---|---|---|---|---|---|
| 24 | `MATEBRIDGE_FPS`, `MATEBRIDGE_BITRATE_KBPS` | VS:77-82 | T-045/T-086 | debug-only (the env bitrate wins over STREAM_PREFS, so it must appear in `ev=profile`) | T-204 (profile) |
| 25 | `MATEBRIDGE_CODEC`; `MATEBRIDGE_H264_PROFILE` | VS:83; EK:13, :166; `host-mac/Sources/MateBridgeCore/Video/EncodeBench.swift:95-99`; `SharpnessBenchOptions.swift` | T-082/T-086; NOTES.md:538 | CODEC: debug-only. H264_PROFILE: retire | T-204 |
| 26 | `MATEBRIDGE_REFRESH=60/120` | VS:84-85; `StreamCoordinator.swift:190` | T-017 | debug-only | T-204 (profile) |
| 27 | `MATEBRIDGE_FRAME_DELAY=0/1` | VS:19, :53-56, :86; HE:164-166 | T-017 (never measured or adopted) | retire | T-204 |
| 28 | `MATEBRIDGE_ENCODER=llrc/fast` | HE:132-135; `EncoderProfile.swift:10` | T-053/T-087 | debug-only | T-204 (profile) |
| 29 | `MATEBRIDGE_IDLE_REFRESH_MS`, `_COUNT`, `_KEY`, `_BUFFER`, `_QP` (timer, QP boost, copy pool) | EK:38, :81-90; HE:79-86, :124-128, :430-472 | T-086/T-087; NOTES.md:566-581 (222-byte skip frames, ineffective) | retire (keep `resubmitLast`, the static-keyframe path) | T-204 |
| 30 | `MATEBRIDGE_PRIO_SPEED=0`; `MATEBRIDGE_QUALITY` | EK:164-165; HE:167-181, :188-189 | T-086; NOTES.md:546-548 | PRIO_SPEED: retire. QUALITY: debug-only | T-204 |
| 31 | `MATEBRIDGE_KEYFRAME_INTERVAL_S` | `KeyframeIntervalPolicy.swift:20` | T-075 | debug-only | T-204 (profile) |
| 32 | `MATEBRIDGE_INPUT_RETAG=0` | `InputColorTags.swift:36-38`; EK:153-163 | T-113; NOTES.md:777-806 | retire (`=0` reproduces a known colour/latency bug) | T-204 |
| 33 | `MATEBRIDGE_WIFI_BITRATE_KBPS` | `TransportBitrate.swift:20-28` | T-088 | debug-only (input to H03; T-178 adds a Wi-Fi default) | T-204 (profile) |
| 34 | `MATEBRIDGE_SERVICE_CLASS` | TK:21-43 | T-088/T-124 | debug-only | T-204 (profile) |
| 35 | `MATEBRIDGE_VIDEO_SOCKET=nw`, `MATEBRIDGE_CONTROL_SOCKET=nw` | TK:79-95, :138-153; SS:3, :34-38, :112-115, :336-375, :561-600, :955-987, :1125-1205; `TcpSocketProbe.swift` (NWConnection variant) | T-091/T-092/T-111; NOTES.md:620-631 | retire (**user confirmation**). Bonjour must stay on `BonjourAdvertiser` (SS:227, :1075) | T-186 |
| 36 | `MATEBRIDGE_NOTSENT_LOWAT_KB` | TK:98-112 | T-091 | debug-only (H03 tuning) | T-204 (profile) |
| 37 | `MATEBRIDGE_SENDQ_LOG`, `MATEBRIDGE_LAT_TRACE` | TK:71-75; `LatencyCsv.swift:13` | T-070/T-088 | keep (diagnostic) | — |
| 38 | `MATEBRIDGE_TCP_LOG` | `TcpInfoLog.swift:129-140` | T-126 | keep (diagnostic; default auto = Wi-Fi only) | — |
| 39 | `MATEBRIDGE_AUDIO=off` | `AudioStreamer.swift:32-35` | T-094 | debug-only | T-204 (profile) |

*Host CLI modes (4) and build-time knobs:*

| # | Knob | Where | Card | Class |
|---|---|---|---|---|
| 40 | `--dump-video`, `--encode-bench`, `--sharpness-bench`, `--inject-test` | `host-mac/Sources/MateBridgeApp/main.swift:6-9` | T-011/T-047/T-086/T-023 | keep (tooling; moving them to a separate executable is optional, not carded) |
| — | `MATEBRIDGE_SIGN_IDENTITY` | `scripts/bundle-host.sh` | T-006 | keep (build-time) |
| — | `--ei draw_scale` | gone | T-144 reverted | already retired |

**Tally:**
- Retire: client rows 3, 4, 6, 9, 10, 12, 13, 16; host H264_PROFILE (25), 27, 29, PRIO_SPEED (30), 32, 35.
- debug-only: about 18, including row 15 pending T-127.
- keep: client 5, 11, 22; host 37, 38, 40.

**Planned knobs from this backlog** (add rows when they land, all default off):
- T-177 bitrate step knob;
- T-196 `MATEBRIDGE_WIFI_ADAPT`;
- T-197 `ctl_lowat_kb`;
- T-198 `MATEBRIDGE_PEN_PLAYOUT_MS`.

**Closing T-019 and T-067:**
- `scripts/board.sh` only knows the statuses `in-progress`, `review`, `blocked`, `todo` and `done`. A `won't-do` status would make the cards disappear from BOARD.md. Close both the way T-144 was closed: `status: done`, plus a dated orchestrator note "Kapatıldı: yapılmayacak (karar 0026)".
- T-019 note: its GL jitter-buffer part is retired with the GL path (T-184). Its Wi-Fi low-latency-lock part was superseded by T-089 (the `wifi_ll` knob), which stays debug-only until T-127 re-measures it.
- T-067 note: keep_jitter/recenter were inconclusive and are retired by T-183.

**Downstream:** T-183, T-184, T-185, T-186 and T-204 depend on this card. T-183, T-186 and T-204 can start in parallel after it (no shared files). T-186 retires the `nw` sockets; T-204 (split from T-186 on 2026-10-03) retires the host encoder knobs and adds the host `ev=profile`.

Wire: none.

## Kapsam dışı

- Any code removal (T-183 … T-186, T-204).
- Re-measuring the Wi-Fi knobs (T-127).
- Moving the host CLI modes to a separate executable.

## Kabul kriterleri

- [ ] [doc] The existing proposed draft `docs/decisions/0026-experiment-knobs.md` (commit 3e1c3c7; it already has the K4 exception) is updated: add the open point on the jitter buffer 1–2 branch and the per-row file references (or a pointer to `docs/KNOBS.md`), record the user's answers (GL, `nw`, jitter), and set the status to accepted.
- [ ] [doc] The user has accepted 0026 and has explicitly confirmed retiring the GL presentation path and the `nw` sockets. The answer is recorded in the decision.
- [ ] [doc] `docs/KNOBS.md` (Turkish prose, table as above) covers all 33 client extras (+4 `net_bench` sub-keys), all 25 host env vars and the 4 CLI modes, each with file reference, card, default, class, outcome and executing card. Row counts are checked against a fresh `grep` at the commit.
- [ ] [doc] T-019 is closed as won't-do with the note that its Wi-Fi-lock part was superseded by T-089 (`wifi_ll`, kept until T-127). T-067 is closed as won't-do. Both use `status: done`, so they stay on the board.
- [ ] [doc] `./scripts/board.sh` is re-run and `backlog/BOARD.md` is committed.

## Plan

1. Envanteri HEAD'de (`ef264dd`) yeniden doğrula: istemci `getXxxExtra("…")` + `EXTRA` sabitleri (`MainActivity`, `WifiKnobs`, `AudioPlayout`/`SinkPolicy`/`AudioBufferConfig`, `bench/NetBench.kt`), host `"MATEBRIDGE_*"` dizgileri ve `main.swift` CLI kipleri. Satır numaralarını a30c769'dan HEAD'e güncelle; varsayılanları koddan oku.
2. `docs/KNOBS.md` yaz (Türkçe): sınıf tanımları, üç tablo (istemci 33 + 4 `net_bench` alt anahtarı, host 25 env, 4 CLI + derleme zamanı), her satırda dosya:satır, kart/kanıt, varsayılan, sınıf, sonuç, uygulayan kart; sayım komutları ve sonuçları; jitter 1–2 açık noktası; planlanan ayarlar; kapsam dışı okunan anahtarlar.
3. `docs/decisions/0026-experiment-knobs.md`: jitter 1–2 açık noktasını, `docs/KNOBS.md` işaretçisini ve kullanıcı cevaplarını (GL, `nw` onaylı; jitter) ekle. Durum satırı zaten "kabul (2026-10-03)", değişmez.
4. T-019 ve T-067: `status: done` + tarihli orkestratör notu "Kapatıldı: yapılmayacak (karar 0026)".
5. `./scripts/board.sh` çalıştır, `backlog/BOARD.md`'yi commit'le; `./scripts/check.sh`; Handoff.

Riskler: kod değişikliği yok. Satır numaraları T-183…T-204 birleştikçe kayar; tablo HEAD SHA'sını belirtir.

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
