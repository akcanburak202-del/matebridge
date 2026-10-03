---
id: T-197
title: Experiment knob: TCP_NOTSENT_LOWAT on the client control socket
status: todo
phase: 6
owner: android-client-dev
depends_on: [T-127, T-171]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionController.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/QuickAck.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/NotSentLowat.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/WifiKnobs.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/DevKnobs.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/session/
  - backlog/tasks/T-197-client-ctl-lowat-knob.md
---

## Amaç

**Gated: start only after T-127 shows uplink stall evidence on Wi-Fi: in topology 2 or 3, in at least 2 of 3 runs, host T-171 `ev=input_age` (recorded in the same T-127 or T-179 session) has pen/pointer p99 > 100 ms or `late_250ms` > 0, while the client `MB/input` line shows `merged=` ≈ 0 in the same seconds (the backlog sits in the kernel, not in `SendQueue`), and the T-127 `tos_ctl 0xB8` + `wifi_ll` row did not remove it. Without that evidence this card stays parked.**

On a Wi-Fi stall the tablet's input first fills the kernel send buffer of the control socket, where its age is invisible. `SendQueue` stays empty, so `congested()` is false and hover/scroll coalescing never starts; the first relief is the 1 s overflow reconnect. An opt-in `TCP_NOTSENT_LOWAT` on the control socket makes the blocking writer stop early, so the existing app-side bounds see the stall within tens of ms. Default off; it is an experiment knob.

Source: external architecture review 2026-10-03 (IN11, M04); verification: docs/reviews/2026-10-03/verify-F-network.md.

## Bağlam

**Evidence (HEAD a30c769):**
- The control socket sets only `tcpNoDelay` (`SessionController.kt:641`); no `SO_SNDBUF` cap, no `TCP_NOTSENT_LOWAT`. The writer thread `mb-ctl-write-<gen>` (`:648`) takes from `SendQueue`, seals, and does a blocking `out.write` (`writerLoop` `:762-786`, write at `:778`).
- `SendQueue`: hard bound 256 KiB / 1000 ms (`SendQueue.kt:14`), congestion signal 8 KiB or 50 ms (`SendQueue.kt:96-100`). The age check runs at `offer` only; PINGs every 500 ms make sure it is evaluated (F IN11 note 3).
- Linux initial `tcp_wmem` is typically 16 KiB, i.e. several hundred ms of pen data (~20–30 KB/s at ~360 Hz), so the kernel absorbs a stall before the app notices (F IN11 note 2). The actual size on HarmonyOS is a device check.
- Precedent for a per-socket option with a dup'd fd: `QuickAck.forSocket` (`QuickAck.kt:34-48`, `ParcelFileDescriptor.fromSocket` + `Os.setsockoptInt`, failure logged once, session unaffected) and its `QuickAckTest`.
- Knob parsing today: `WifiKnobs.parse` (`WifiKnobs.kt:29-32`), called from `MainActivity.parseWifiKnobs` (`MainActivity.kt:310-313`).

**Plan hints (F F-5):**
- `--ei ctl_lowat_kb N` (e.g. 4…64; absent = off). Linux `TCP_NOTSENT_LOWAT` = 25 (`linux/tcp.h`), value in bytes, set after connect. Linux applies it to blocking `sendmsg` through `sk_stream_memory_free`; verify on the HarmonyOS kernel, which may refuse the option (then log once and continue).
- Log `ctl_lowat_kb=` in the session-start knob fields, and the socket's `sendBufferSize` once (numbers only).
- Put the setsockopt wrapper either in `QuickAck.kt` (shared fd helper) or a new `NotSentLowat.kt`; choose one in Plan.
- After T-185 the debug knobs move to `DevKnobs.kt` and are honoured only with `--ez dev true` (decision 0026). Put the knob where T-185 left the Wi-Fi knobs; if `WifiKnobs.kt` still exists (audit K4 keeps it until T-127 reports), add it there.
- Add the knob to `docs/KNOBS.md` and the log field to `docs/LOGGING.md` via *Açık sorular* (orchestrator).
- Risk: the overflow path (reconnect + host release-all) triggers sooner on a long stall. That is correct by the bounded-queue rule but user-visible, so the default stays off. Never drop a release: this card changes no merge rule (contact pen samples, key/button ups and stroke boundaries stay unmergeable, `InputOutbox.kt:36-56, 103-126`).

**Serialize with** T-185 (`MainActivity.kt`; chain … → T-185 → T-191 → T-197) and T-160 (`SessionController.kt`; chain T-150 → T-156 → T-159 → T-160 → T-197). `WifiKnobs.kt` is touched only by this card (T-183 no longer deletes it).

**Device procedure** (orchestrator): Wi-Fi topology 3, hover plus scroll during a forced full-screen burst, 5 min, ≥ 3 runs knob off and ≥ 3 runs with `--ei ctl_lowat_kb 16` (and one other value), same build. Record `merged=`, overflow/reconnect count, host `input_age` p99 and `late_250ms`.

Wire: none.

## Kapsam dışı

- Changing the 256 KiB / 1 s bounds or the 8 KiB / 50 ms congestion thresholds.
- Dropping or merging contact samples, key or button events (freshness policy is T-199 / decision 0025).
- Making the knob the default (needs its own decision with the device data).

## Kabul kriterleri

- [ ] [JVM] Knob parse: absent → off; out-of-range → off (or clamped, documented); without `dev` after T-185 → ignored and listed.
- [ ] [JVM] Setsockopt wrapper with a fake setter: success applies once per connection; failure is logged once and the session continues (modelled on `QuickAckTest`).
- [ ] Session-start log carries `ctl_lowat_kb=` (`-` when off) and `sndbuf=` once; no other new log lines.
- [ ] [device] Knob off: behaviour and logs identical to today.
- [ ] [device] Knob on, Wi-Fi topology 3 per the procedure: `merged=` rises during bursts (coalescing now starts), host `input_age` p99 is lower than with the knob off, and reconnects/overflows per 5 min do not rise in normal use. Results in NOTES with build IDs; the orchestrator records keep/retire in `docs/KNOBS.md`.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

_(Ajan kodlamadan önce doldurur: adımlar, dokunulacak dosyalar, riskler.)_

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
