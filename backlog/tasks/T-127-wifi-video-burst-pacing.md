---
id: T-127
title: Measure the Wi-Fi baseline across three topologies before any congestion code
status: todo
phase: 6
owner: orchestrator
depends_on: [T-126, T-168, T-170, T-173]
decisions: []
files:
  - backlog/tasks/T-127-wifi-video-burst-pacing.md
  - docs/NOTES.md
  - tools/wifi-trace/
---

## Amaç

On Wi-Fi, full-screen changes push 100–450 KB per frame into the air, control srtt rises from 20 to 60–100 ms and audio underruns, even though control and video use separate sockets with WMM classes (NOTES 2026-10-02 ~13:20). That finding was measured only with the Mac also on Wi-Fi, never with the Mac on Ethernet, and never against budgets set beforehand. This card re-scopes T-127 from "try some fixes" to the measurement baseline: the same scripted workload over USB, Mac Ethernet + tablet Wi-Fi, and both on Wi-Fi, with budgets written down before the runs. The result decides decision 0023's branch (a fixed Wi-Fi profile, T-178, or adaptive control, T-195/T-196) before any congestion code is written. It also re-measures the tablet Wi-Fi TOS/`wifi_ll` knobs, whose earlier "no effect" result was confounded.

Source: external architecture review 2026-10-03 (H03, X8, D6, A3, LM7); verification: docs/reviews/2026-10-03/verify-F-network.md ("T-127 (re-scoped)", H03.d, X8, D6, A-1, A-5), docs/reviews/2026-10-03/coverage-audit.md (K2, K4).

## Bağlam

**Re-scope (2026-10-03).** The diagnosis below and in *Önceki kapsam* is kept. Step mapping of the old card:
- Old steps 1 (Mac on Ethernet) and 2 (lower the Wi-Fi bitrate from the panel) become rows of the matrix.
- Old step 3 (host in-flight/pacing card) is **superseded** by T-178, T-195 and T-196 via decision 0023.
- Old step 4 (raise the Wi-Fi audio share to ~100 ms) stays the documented last resort.
- Phase moves 5 → 6. Owner stays orchestrator; the user runs the hardware (Mac Ethernet cable, tablet, workload).

**Evidence (verify-F):**
- The measured burst finding (`docs/NOTES.md:970-991`): video `snd_cwnd` 2–13 MB, 100–450 KB in flight, control srtt 20 → 60–100 ms, 13 underruns in 5 min, no retransmits on control. Delay is queueing, not loss (A3).
- That run had the Mac on Wi-Fi: `en1`, channel 52 (5 GHz DFS, 160 MHz), `awdl0` active, Ethernet not connected (NOTES ~l.953). Two wireless hops.
- The host already marks control AC_VO and video AC_VI by default (T-124). The tablet uplink is unmarked unless `--ei tos_ctl` is given (`client/session/WifiKnobs.kt`).
- The video sender already bounds kernel **unsent** bytes (`TCP_NOTSENT_LOWAT` 128 KiB); in-flight (unacked) bytes and single-frame burst size are not bounded (H03.a).
- **LM7 / coverage K2:** the delay is AP/driver queueing behind bursts and two-hop contention, not serialisation at the encoder rate. The raw Mac→tablet link carried ~410 Mbit/s per flow with no loss (`docs/NOTES.md:603-610`); 60 Mbps is the stream bitrate, not link capacity.
- **F A-5:** T-126 `unacked_bytes`/`notsent_bytes` are an estimate that degenerates to `unacked = sbbytes`, `notsent = 0` when cwnd ≫ sbbytes (`host-mac/Sources/MateBridgeCore/Session/TcpInfoLog.swift:62-67`). Read them as **sbbytes**.
- **F A-1:** host-side queue drops force an IDR with no rate limit, which may feed back under Wi-Fi back-pressure. The `net ev=stats` `idr=`/`idr_bytes_max=` fields (T-122) show it. T-176 fixes it and may land before this card; record whether it is in the build.
- **Coverage K4:** the 2026-10-01 "DSCP/`wifi_ll` had no effect" rows (`docs/NOTES.md:588-598`) were measured on the old `nw` stack while the link was capped at 27–28 Mbps, so no marking could show an effect. The knobs stay (debug-only) until this card's knob row reports. Then the orchestrator records keep or retire in `docs/KNOBS.md` (created by T-182) in a separate commit; `docs/KNOBS.md` is not in this card's `files:`.

**Budgets — write these into NOTES before the first run, do not change them after:**
- audio underruns ≤ 1 per 5 min;
- control srtt p95 ≤ 40 ms;
- client capture→decode p95 (T-168 `cap_dec_p95_us`) ≤ 70 ms on Wi-Fi.

**Procedure (orchestrator + user, one device run at a time):**
1. Build check: record host and APK SHAs (T-145/T-146) with `scripts/device-smoke.sh` (T-173); note whether T-176 is in the build. Host env `MATEBRIDGE_SENDQ_LOG=1` (and `MATEBRIDGE_LAT_TRACE=1` for the T-170 `pts_vs_deliv` numbers).
2. Network notes per session: Mac interface, `ifconfig awdl0` state, channel / width / DFS of the AP, signal.
3. Workload script (5 min, identical every run): full-screen pan/scroll of a long page, Krita pinch zoom, app switching, Apple Music playing throughout.
4. Topologies, ≥ 3 runs each, measure the Ethernet row first:
   - (1) USB;
   - (2) Mac on Ethernet + tablet on Wi-Fi;
   - (3) Mac and tablet both on Wi-Fi.
5. Extra rows on topology 3 (≥ 3 runs each):
   - bitrate 30 Mbps and 15 Mbps via the panel (old step 2);
   - **knob row:** default bitrate with `--ei tos_ctl 0xB8 --ez wifi_ll true`. Add `--ez dev true` if T-185 is in the APK build (T-185 gates these keys behind `dev`). A run counts only if the client log shows the knobs took effect: `ev=dev_knobs ignored=-` (with T-185), `ev=wifi_knobs … tos_ctl=0xb8 … wifi_ll=1`, `ev=traffic_class sock=control requested=0xb8` (record its `applied=` value), and `ev=wifi_lock held=1`;
   - **per-knob split:** if the combined knob row beats the default row on control srtt p95 or on underruns, run ≥ 3 runs each of `tos_ctl` only and `wifi_ll` only;
   - `tos_video` marks only the tablet's uplink ACKs on the video socket. Give it one combined run with `--ei tos_video 0x88`, or record it as "not measured → retire with the row verdict".
   - **static text:** at each topology-3 bitrate row (default, 30 and 15 Mbps), the user judges static text quality on a settled screen (sharp enough for daily use: yes / no). Record the verdict per row.
6. Per run, record:
   - host `net ev=tcp`: control and video srtt p50/p95/max, sbbytes p95/max, retx;
   - host `ev=sendq` summary;
   - host `idr=`/`idr_bytes_max=` per second;
   - host `ev=input_age` (T-171, if it is in the build): pen and pointer p50/p95/p99/max, `late_250ms`, `clock_unc_us` p95. If T-171 is not in the build, write "not available";
   - client `MB/input` `merged=` (summed per run) next to `ev=input_age`. For every second with pen/pointer p99 > 100 ms or `late_250ms` > 0, also note that second's `merged=`. Uplink stalls (input for T-197) show as high age with `merged=` ≈ 0 in the same seconds;
   - client audio `underruns` and `owd_ms_p95`;
   - client T-168 `cap_dec`, `ready_slot` and `cap_rel` p50/p95; fps.
   - **Replay trace (once, topology 3, default bitrate, one representative run):** extract a numbers-only trace into `tools/wifi-trace/` (CSV + `README.md` with the recipe, build SHAs and topology; precedent `tools/pacing/trace7_120hz_excerpt.csv`). Columns:
     - per frame, from `latency.csv` (`MATEBRIDGE_LAT_TRACE=1`): `enqueued_us`, `write_start_us` and `write_done_us`, rebased to 0;
     - per second: `net ev=stats` `sent_kbps=`/`idr=`/`idr_bytes_max=` and video `ev=tcp` srtt/sbbytes/retx.

     No addresses, device IDs, serials, key data or coordinates. At HEAD no log carries per-frame encoded bytes. If the replay needs them (T-195), write that under *Açık sorular* as a small host logging follow-up instead of changing code here. This trace is the source for T-195's golden replay.
7. Summarise with `tools/measure/` (T-173), compare against the budgets, write the NOTES entry.
8. Optional in the same session: T-179 (pen arrival rhythm, same three topologies).

**Decision rule for 0023 (fixed before the first run, like the budgets):**
- A topology-3 bitrate row *passes* when ≥ 2 of its 3 runs meet all three budgets.
- **"Fixed profile suffices"** iff at least one topology-3 bitrate row (default, 30 or 15 Mbps) passes **and** the user accepts static text at that row. The chosen Wi-Fi value for T-178 is the highest such bitrate.
- **"Go adaptive"** iff no topology-3 bitrate row passes, or the user rejects static text at every row that passes.
- Topology 2 is reported too. If it passes at the default bitrate while topology 3 does not, NOTES also records "Mac on Ethernet" as advice. The 0023 branch is still decided on topology 3.

**What the result unlocks:**
- "Fixed profile suffices" → T-178 (host Wi-Fi default bitrate).
- "Go adaptive" → T-195, then T-196.
- Uplink stall evidence → T-197.
- Knob keep/retire per knob → recorded in NOTES; the orchestrator copies it to `docs/KNOBS.md` (T-182) in a separate commit.

**Open questions for the user (manifest §5 Q8):** is Wi-Fi meant to become a primary path or stay a fallback (this sets the H03 priority)? Can the Mac-on-Ethernet test be run?

## Kapsam dışı

- Code changes of any kind. Congestion control, live bitrate and IDR fixes are T-176, T-177, T-178, T-195, T-196.
- UDP/QUIC (review A4; only after decision 0023 step (c)).
- Pen rhythm (T-179, optional in the same session).

## Kabul kriterleri

- [ ] [doc] The three budgets and the 0023 decision rule above are recorded in NOTES, dated, **before** the first run.
- [ ] [device] Topologies 1, 2 and 3 each run ≥ 3 times with the same 5 min workload; per run the host `ev=tcp` (control/video srtt p50/p95/max, sbbytes p95/max, retx), `ev=sendq`, `idr=`/`idr_bytes_max=` per second, client underruns/`owd_ms_p95`, T-168 latency percentiles and fps are in NOTES.
- [ ] [device] Topology 3 at the default bitrate, 30 Mbps and 15 Mbps, ≥ 3 runs each, in NOTES.
- [ ] [device] Topology 3 with `--ei tos_ctl 0xB8 --ez wifi_ll true` (plus `--ez dev true` if T-185 is in the build), ≥ 3 runs, in NOTES. Each counted run shows `ev=dev_knobs ignored=-` (with T-185), `ev=wifi_knobs … tos_ctl=0xb8 … wifi_ll=1`, `ev=traffic_class sock=control requested=0xb8` (with its `applied=` value recorded) and `ev=wifi_lock held=1`. If the combined row beats the default row on control srtt p95 or underruns, `tos_ctl`-only and `wifi_ll`-only rows (≥ 3 runs each) are in NOTES too.
- [ ] [doc] NOTES gives a keep/retire verdict **per knob** (`tos_ctl`, `tos_video`, `wifi_ll`/WifiLock). `tos_video` is either measured in one combined run with `--ei tos_video 0x88` or recorded as "not measured → retire with the row verdict". The orchestrator records the verdicts in `docs/KNOBS.md` in a separate commit.
- [ ] [device] The user's static-text verdict (yes/no) is recorded for each topology-3 bitrate row.
- [ ] [doc] Per run, NOTES has `ev=input_age` pen/pointer p50/p95/p99/max and `late_250ms` (or "not available" without T-171) and the client `merged=` total.
- [ ] [doc] A numbers-only topology-3 replay trace with its `README.md` is committed under `tools/wifi-trace/` (per-frame send timing, per-second bytes and `ev=tcp` values), with no personal or device identifiers.
- [ ] [doc] Every NOTES row names the build SHAs (host and APK), whether T-176 is included, the topology, AWDL state, channel/width/DFS, bitrate and run count; `unacked_bytes` is reported as sbbytes.
- [ ] [doc] NOTES records the result against the budgets and the decision 0023 branch, chosen by the decision rule above ("fixed profile suffices" with the chosen Wi-Fi value / "go adaptive"). It also records whether uplink stalls were seen (high `input_age` with `merged=` ≈ 0; input for T-197).

## Önceki kapsam (2026-10-02)

Former title: *(İleride) Wi-Fi — büyük video patlamalarının sesi geciktirmesi; bit hızı / gönderim hızı sınırı / Ethernet ile yeniden değerlendir* (phase 5, owner orchestrator, depends_on [T-126]).

**Kullanıcı kararı (2026-10-02):** "şimdilik Wi-Fi modu idare eder, mükemmel olmasına gerek yok; ileride tekrar inceleriz." Bu kart o not.

Bulgu (NOTES 2026-10-02 ~13:20):
- Wi-Fi'de tam ekran değişimlerinde (pinch, uygulama değiştirme) video 100–450 KB'yi tek seferde havaya veriyor; `snd_cwnd` sınırsız büyüyor (2–13 MB).
- Kablosuz kuyruk dolunca ses de (ayrı TCP, AC_VO) 60–100 ms gecikiyor ve alt taşma oluyor. 5 dk'da 13; T-125 sayesinde hemen toparlanıyor.
- USB'de sorun yok.

Denenecekler (sırayla):
1. Mac'i Ethernet'e bağla (kullanıcı uygun zamanda deneyecek) ve aynı testi tekrarla: `ev=tcp` ile kontrol `srtt` ve alt taşma sayısı.
2. Panelden Wi-Fi bit hızını düşür (örneğin 30 Mbps) ve karşılaştır.
3. Gerekirse host kartı: Wi-Fi'de video soketinde havadaki veriyi / gönderim hızını sınırla (pacing, `TCP_NOTSENT_LOWAT` + uygulama düzeyinde bayt bütçesi), gecikme ve keskinlik etkisini ölç.
4. Son çare: Wi-Fi ses payını ~100 ms'ye çıkarmak.

Former *Plan*: _(Değerlendirme zamanı gelince.)_

## Plan

_(Ajan kodlamadan önce doldurur: adımlar, dokunulacak dosyalar, riskler.)_

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
