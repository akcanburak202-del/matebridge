---
id: T-194
title: Run the 8 h soak, then one week of real use, with resource trends
status: todo
phase: 6
owner: user + orchestrator
depends_on: [T-173, T-157, T-164, T-167, T-193]
decisions: []
files:
  - docs/NOTES.md
  - backlog/tasks/T-194-soak-8h-week.md
---

## Amaç

The goal is to use the tablet as the Mac's sole main screen. The only long-run evidence is one 30-minute test on an old build, from before audio, files, sleep/WoL and the game modes existed. PLAN Aşama 4's own exit criterion ("bir hafta boyunca günlük iş… 'yeniden başlatmam gerekti' türünden sorun kalmıyor") and the Aşama 6 "Bitti" line need recorded evidence: one 8 h real-work day with resource trends, then one week of real use with daily summaries. This card produces that evidence.

Source: external architecture review 2026-10-03 (D10, X13, M07, SE6); verification: docs/reviews/2026-10-03/verify-H-hygiene.md (SOAK-1, D10, SE6), docs/reviews/2026-10-03/verify-E-measurement.md (W6 procedure) and docs/reviews/2026-10-03/verify-D-display.md (X13).

## Bağlam

**Evidence at HEAD:**
- The only sustained run is `docs/NOTES.md:149-155` (2026-09-30, 30 min, USB):
  - Mac RSS 64 MB flat, tablet PSS 68–73 MB, 0 disconnects;
  - the build predates audio, files, sleep/WoL and the game modes.
- The PLAN Aşama 4 exit is unchecked (`docs/PLAN.md:173`).
- The monitoring tools were scratch-only and lost (`docs/NOTES.md:1070, 1119`). T-173 versions them (`tools/soak/`, `tools/measure/`, `scripts/device-smoke.sh`).
- `docs/NOTES.md:152` warns that `ps %cpu` prints a decimal comma in the Turkish locale. The samplers must handle it.
- verify-D X13: run this only after H01/H02/H04 have landed, otherwise the soak measures known issues. Hence `depends_on`:
  - T-157 (trust acceptance);
  - T-164 (video-fault churn run);
  - T-167 (display keep);
  - T-173 (tools);
  - T-193 (the "Last verified" pair to compare against).

**Roles:** the orchestrator prepares the run (tools from T-173, header, thresholds) and writes the analysis into NOTES. The user does the real work and keeps the daily one-line notes. Device runs happen one at a time (CLAUDE.md).

**Procedure (step by step):**
1. **Baseline:**
   - Run `scripts/device-smoke.sh` and copy its header into NOTES: host SHA, APK SHA, macOS build, HarmonyOS build (`ro.build.display.id`), transport, mode, resolution, target and real Hz, bitrate, codec;
   - note the content type (work apps, Krita, video) and the planned duration;
   - confirm that no experiment knob is active (the `ev=profile` lines from T-185/T-186 show defaults).
2. **Thresholds, agreed before the run.** Proposed, the orchestrator confirms:
   - between hour 1 and hour 8, the linear slope of host RSS and tablet PSS stays below 2 MB/h;
   - thread and FD counts, sampled in the same state (session live, idle desktop), end within baseline +5;
   - `dumpsys media.codec` instances return to the baseline count after each reconnect.
3. **8 h real-work day.** Start the T-173 samplers: host `macmon`/soak sampler and tablet sampler, every 60 s:
   - host RSS, `lsof -p` count and thread count;
   - tablet PSS, `/proc/<pid>/fd` count, threads grouped by prefix (`mb-ctl-read-*`, `mb-video-*`, `mb-audio-*`, `mb-decoder*`), and `dumpsys media.codec` / `media.resource_manager` instances.
   During the day include:
   - at least one USB↔Wi-Fi switch (unplug/replug);
   - one lock/unlock;
   - one tablet app background/foreground.
4. **Event counts** from the logs, numeric only:
   - `decoder_give_up`, `decoder_previous_stuck`, `detach_slow`, `audio_previous_slow`, `api=` audio fallbacks;
   - `pipeline_retry`, `release_all` (host owed releases must be 0), reconnects;
   - video-fault overlay events (T-159).
5. **Restart-requiring events:** count every manual host relaunch, tablet app relaunch, adb restart, re-pair or Mac reboot needed to recover. Record the cause of each and which log line preceded it.
6. **Overnight:** leave the session in place so that the Mac sleeps overnight (display sleep and system sleep). In the morning record:
   - time to first image;
   - whether windows stayed on the virtual display (T-167 keep time);
   - whether a restart was needed.
7. **Analysis:** `tools/soak/summarize.py` prints the slopes, the counts and a pass/fail against step 2's thresholds. NOTES gets the summary table, not the raw logs.
8. **One week:** daily use with whatever transport and mode the user chooses. Each day add one summary line to NOTES:
   - date;
   - hours used;
   - transport;
   - mode;
   - restart-requiring events (count and cause);
   - anything odd.
   Run the samplers on at least one more full day if time allows.
9. **Close:** list anything not run explicitly as "not run". If the week passes, the orchestrator ticks PLAN Aşama 4 "Bitti" in a separate doc commit; `docs/PLAN.md` is not in this card's `files:`.

**Privacy (AGENTS.md):**
- the samplers and summaries carry numbers and event names only;
- no key characters, text, clipboard content or file names;
- no device serial numbers;
- raw logs are never committed.

**Split suggestion:** if a fix becomes necessary mid-run, stop and open a card for it. The 8 h day and the week can then be recorded as two NOTES entries under this same card.

## Kapsam dışı

- Fixing anything found; each finding gets its own card.
- Recovery rehearsals (host kill, permission loss, reboot); those are T-147.
- Optical latency (T-174) and Wi-Fi baseline numbers (T-127).

## Kabul kriterleri

- [ ] [doc] Every result header in NOTES names: both SHAs, the macOS and HarmonyOS builds, transport, mode, resolution, target and real Hz, bitrate, content and duration.
- [ ] [device] The 8 h real-work run is recorded. It shows no monotonic growth in threads, FDs or PSS/RSS: slopes and end values are within the thresholds agreed in step 2, which are written in the same NOTES entry.
- [ ] [device] Event counts (step 4) and restart-requiring events (step 5, with causes) are recorded. The host owed-release count is 0.
- [ ] [device] The overnight sleep result (step 6) and at least one USB↔Wi-Fi switch during the day are recorded.
- [ ] [doc] One week of daily one-line summaries is in NOTES, followed by a week summary: total restart-requiring events and a verdict against PLAN Aşama 4 "Bitti".
- [ ] [doc] Anything not run is listed as "not run". No raw logs, serial numbers or personal data are committed.

## Plan

_(Ajan kodlamadan önce doldurur: adımlar, dokunulacak dosyalar, riskler.)_

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
