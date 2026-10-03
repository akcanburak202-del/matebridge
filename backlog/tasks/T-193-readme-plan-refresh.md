---
id: T-193
title: Rewrite the README to the current state; refresh PLAN status; record the version pair
status: todo
phase: 6
owner: orchestrator
depends_on: [T-145, T-146, T-147]
decisions: []
files:
  - README.md
  - docs/PLAN.md
  - backlog/tasks/T-193-readme-plan-refresh.md
---

## Amaç

The README still says "Phase 0: platform probes. Nothing usable yet", although the system is a hardware-tested daily setup. `docs/PLAN.md`, which CLAUDE.md and AGENTS.md point every agent at, has stale hardware and status lines. The README should become the single "current product state" page: what works, known limits, how to choose a mode, the last verified version pair, and a link to the recovery runbook. NOTES stays the research log.

Source: external architecture review 2026-10-03 (L01, P1, D9; audit PF5 residual and K3); verification: docs/reviews/2026-10-03/verify-H-hygiene.md (DOC-1, additional issue 8, §P1) and docs/reviews/2026-10-03/coverage-audit.md (K3, PF5).

## Bağlam

**Stale text at HEAD (re-check before editing):**
- `README.md:5`: `> Status: **Phase 0: platform probes.** Nothing usable yet.`
- The Layout block (`README.md:17-27`) omits `tools/` (`tools/pacing/`, `tools/dav-repro/`, and `tools/measure/` + `tools/soak/` once T-173 merges) and the scripts `install-apk.sh`, `usb-mode.sh` and `bundle-host.sh` (`scripts/device-smoke.sh` after T-173). It says nothing about audio, clipboard, tablet files (WebDAV over USB), encryption, the stream modes, or sleep/WoL.
- `docs/PLAN.md:9`: "Şu an 1920×1080 bir monitör bağlı." **Wrong (audit K3).** The 1920×1080 display (`v0x756e6b6e/m0x76697274`) is the headless Mac's placeholder display, not a physical monitor (`docs/NOTES.md:160`, 2026-09-30, later than PLAN's 2026-09-29). An HDMI dummy was only an intention (`docs/NOTES.md:31`). Write whatever the T-147 rehearsal established (FileVault, second access path, dummy present or not).
- `docs/PLAN.md:10`: "Model/çözünürlük: **?**" → MatePad Pro 12.2 (2025), 2800×1840 (AGENTS.md; `docs/NOTES.md:160`).
- `docs/PLAN.md:167-169`, Phase 4 items still unchecked although done:
  - sleep/wake recovery: T-128…T-134;
  - the settings panel: decision 0013, T-105;
  - mode choice: the tablet as the sole main screen is the daily use.
  Match them to BOARD/NOTES.
- `docs/PLAN.md:173` "Bitti: bir hafta…" stays **unchecked** until T-194 passes.
- `docs/PLAN.md:179`: "~90 fps" decoder ceiling and "~13–15 ms" encode. Disproved:
  - `docs/NOTES.md:1100-1113` (T-144 sweep): 120 fps at 2800×1840 while drawing, `overflows=0`, host `enc_ms` p50 ~7.2 ms;
  - `docs/NOTES.md:273`: the encoder reaches 120 fps.
  The 120 Hz modes exist (Akıcı, Performans, Oyun 120; decision 0016).
- The "Aşama 6" section was already added by the orchestrator (commit bd4ef0f). It is not part of this card.

**README content checklist:**
- **What works:** display at native resolution (60/120 Hz), M-Pencil pressure/tilt/hover, keyboard/trackpad/mouse, pinch, audio, clipboard, tablet files over USB, encryption and pairing, sleep/WoL, and the five stream modes.
- **Known limits:**
  - Wi-Fi ~40 ms vs USB ~24 ms (`docs/NOTES.md:642-644`);
  - the display grace or keep behaviour as merged at write time (10 s grace, or the T-165/T-167 park and keep time);
  - the decoder-fault input gap: closed if T-159 has merged, otherwise stated as open;
  - SDR/4:2:0 (T-188, if available).
- **Mode guidance (audit PF5 residual):** in Akıcı/Performans the virtual display stays at 120 Hz (`StreamPrefsPolicy.swift:49`, `displayRefreshHz = fps >= 120 ? fps : 60`). DISPLAY_RATE only thins the host's capture/encode (`docs/NOTES.md:350`). So with keyboard-only work, when the panel drops to 60 Hz, Mac apps still render 120 fps while ~60 are shown. Decision 0016 forbids automatic switching, because 60↔120 recreates the display. Advice: for long keyboard sessions prefer **Netlik** (60), and **Oyun 60** for games (Mac GPU 90 % → 54 %, `docs/NOTES.md:1088-1098`).
- **"Last verified":**
  - host SHA and APK SHA, and how to read them (T-145 menu "Sürüm …" line, T-146 panel "Sürüm" row);
  - the macOS build and the HarmonyOS build (`ro.build.display.id`);
  - the date and a recorded `./scripts/check.sh` pass, all taken from the T-147 record.
- **Recovery:** a short list (Parsec or the remote path T-147 confirmed, "Onaylı cihazları unut", USB modu) and a link to `docs/RECOVERY.md` (T-147).
- Keep the Why, Develop and License sections. Never add device serial numbers or personal data (AGENTS.md).

**Coordination:** decision titles 0011–0017 and NOTES 2026-10-02/03 are the fact sources. The runbook itself is T-147, not this card.

## Kapsam dışı

- `docs/RECOVERY.md` content (T-147), the Aşama 6 section, screenshots.
- Any code change.

## Kabul kriterleri

- [ ] [doc] README has no "Phase 0" / "Nothing usable" text and states the current product state (what works, as listed in Bağlam).
- [ ] [doc] The Layout block lists `tools/`, `install-apk.sh`, `usb-mode.sh` and `bundle-host.sh`, plus every T-173 tool that has merged.
- [ ] [doc] Known limits are stated: Wi-Fi vs USB numbers with their NOTES source, display grace or keep as merged, and the decoder-gap status after D3.
- [ ] [doc] The mode guidance paragraph (Netlik 60 for long keyboard work, Oyun 60 for games) is present and cites decision 0016.
- [ ] [doc] A "Last verified" block names the host and APK SHAs, the macOS and HarmonyOS builds, and the date, matching the T-147 NOTES record.
- [ ] [doc] README links `docs/RECOVERY.md`.
- [ ] [doc] PLAN.md:9 says headless 1920×1080 placeholder, not a physical monitor. PLAN.md:10 gives the model and 2800×1840. The Phase 4 checkboxes match BOARD/NOTES, and "Bitti" stays open until T-194. The PLAN.md:179 "~90 fps / 13–15 ms" line is corrected with NOTES references.
- [ ] [doc] No device serial number, IP/MAC address or personal data in either file.

## Plan

_(Ajan kodlamadan önce doldurur: adımlar, dokunulacak dosyalar, riskler.)_

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
