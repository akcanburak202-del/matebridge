---
id: T-149
title: Add a component-split CI merge gate and a safe fixture CLI
status: review
phase: 6
owner: orchestrator
depends_on: []
decisions: [0022]
files:
  - .github/workflows/check.yml
  - scripts/check.sh
  - protocol/fixtures/gen.py
  - protocol/fixtures/README.md
  - docs/WORKFLOW.md
  - docs/PLAN.md
  - docs/decisions/0022-ci-github-actions.md
  - backlog/tasks/T-149-ci-merge-gate.md
---

## Amaç

The only merge gate today is a manual `./scripts/check.sh` on the owner's Mac, and nothing records that it ran for a given merge. In an agent-driven repo that makes "tests pass" unverifiable. This card adds GitHub Actions jobs that run the existing checks split by component on every push, so each commit shows a visible pass/fail, and makes the golden-fixture generator safe so it can never rewrite fixtures by accident. Hardware behaviour stays out of CI and is said so explicitly.

Source: external architecture review 2026-10-03 (M07, P4); verification: docs/reviews/2026-10-03/verify-H-hygiene.md (CI-1, additional issues 1 and 2, P4, M07).
Decision 0022 must be accepted by the user before work starts (manifest §5 Q4).

## Bağlam

- **Evidence (HEAD a30c769):**
  - `.github/` does not exist; there is no `androidTest` tree. CI was deferred on purpose (T-001 l.20, `docs/PLAN.md:48` "atılan / ertelenen") and never carded.
  - `scripts/check.sh` is monolithic and Mac-shaped: it builds every SwiftPM package incl. probes (:16-20), every Gradle project incl. probes (:26-30), falls back to the Android Studio JBR and `~/Library/Android/sdk` only when `JAVA_HOME`/`ANDROID_HOME` are unset (:23-25), runs the CryptoKit vector script (:38-40) and greps fixture stems in `docs/PROTOCOL.md` (:42-47). On a GitHub Ubuntu image (Swift preinstalled) it would try `swift build` of `host-mac` (AppKit) and the CryptoKit script, and fail.
  - `protocol/fixtures/gen.py:460-476`: `check = "--check" in sys.argv`; every other invocation (`--help`, a typo) **rewrites** all 48 fixtures. The verifier triggered this by accident (output was byte-identical, `git status` clean). `protocol/fixtures/README.md:5` documents the bare `python3 protocol/fixtures/gen.py` as the regenerate command.
  - Host tests are Core-only (`host-mac/Package.swift:18`, one test target); Keychain is faked, Bonjour tests self-skip without mDNSResponder, `CGVirtualDisplay` is resolved at runtime (`host-mac/Sources/MateBridgeHost/VirtualDisplay.swift:47-56`), so `swift build`/`swift test` should work on a hosted macOS runner. Android needs AGP 9.4.1, Gradle 9.8.0, compileSdk 37, NDK 30.0.16248370 and CMake 4.1.2 (`client-android/app/build.gradle.kts:7-9`), installed with the runner's `sdkmanager`.
  - The repo is public (`docs/WORKFLOW.md:54`), so hosted macOS minutes are free; path filters still keep the macOS job off pure Android/docs pushes.
- **Plan hints:**
  - `check.sh --only host|android|protocol` (repeatable or comma list); no flag = all, exactly today's behaviour on the Mac. `host` = `host-mac` build+test; `android` = `client-android` `assembleDebug testDebugUnitTest`; `protocol` = `gen.py --check`, the fixture-stem grep and, **on Darwin only**, the CryptoKit vector diff (print an explicit `SKIP (needs macOS)` elsewhere). Probes run only in the default (all) mode, never under `--only`. Keep the existing "respect `JAVA_HOME`/`ANDROID_HOME` when set" guard.
  - `gen.py`: `argparse` with `--check` and `--write` (mutually exclusive, one required); unknown arguments exit non-zero; `--check` output and exit codes unchanged. Update `protocol/fixtures/README.md:5` to `--write`.
  - Workflow: jobs `macos` (`--only host`, `--only protocol`; path filter `host-mac/**`, `protocol/**`, `scripts/check.sh`, `.github/workflows/**`, `docs/PROTOCOL.md`) and `linux` (`--only android`, `--only protocol`). Triggers: push to `main` and `task/**`, plus `workflow_dispatch`. Only first-party `actions/checkout`, `actions/setup-java`, `actions/cache` (Gradle and SwiftPM caches). JDK 21.
  - **Merge-gate mechanics:** today only `main` is pushed, so CI on `main` alone is post-merge. To gate, the orchestrator pushes `task/*` before merging (or opens a PR) and merges only on green. `docs/WORKFLOW.md` gets one line saying this and that CI is advisory for the first week, then required.
  - T-146 derives `versionCode` from the commit count; use `fetch-depth: 0` in the Linux checkout or note that CI APKs are not daily APKs.
  - `docs/PLAN.md:48`: drop "CI" from the "Atılan / ertelenen" list and point to 0022 (that line only; T-193 refreshes the rest of PLAN).
- **Risks:** timing-sensitive tests (e.g. the 5 s bound in `KeychainAsyncTests`, socket deadlines) may flake on shared runners, hence the advisory week; the hosted macOS image may lag the Mac mini's macOS 27 SDK. If `host-mac` cannot build there, record it and the decision's "revisit" clause applies.
- **Not covered by CI (state in 0022 and WORKFLOW):** ScreenCaptureKit, VideoToolbox, `CGVirtualDisplay`, MediaCodec, AAudio, TCC, CGEvent posting, probes.
- No wire change. `gen.py` is orchestrator-owned; only its CLI changes, never the fixture content.

## Kapsam dışı

- Device or instrumentation tests, emulators, release signing, building probes in CI, a self-hosted runner.

## Kabul kriterleri

- [x] `./scripts/check.sh` with no flag behaves exactly as today on the Mac (same steps, same exit code).
- [x] `check.sh --only host|android|protocol` runs only that component; `--only protocol` on Linux skips the CryptoKit diff with an explicit `SKIP` line; set `JAVA_HOME`/`ANDROID_HOME` are never overridden.
- [x] `gen.py` writes only with `--write`, exits non-zero on unknown arguments and on no mode, and `--check` is unchanged; `protocol/fixtures/README.md` documents `--write`.
- [ ] [CI] The macOS job runs `--only host` and `--only protocol`; the Linux job runs `--only android` and `--only protocol`; both pass on the merge commit of this card (run URLs in Handoff).
- [ ] [CI] A deliberately stale fixture on a throwaway branch fails the job (run URL in Handoff; branch deleted afterwards).
- [ ] [CI] Each job finishes in under 15 min with warm caches (times in Handoff).
- [x] [doc] Decision 0022 lists what is NOT covered; `docs/WORKFLOW.md` states the gate mechanics (push `task/*`, advisory week, then required); `docs/PLAN.md:48` points to 0022.
- [x] `./scripts/check.sh` geçiyor.

## Plan

1. **`protocol/fixtures/gen.py`:** `argparse` (`allow_abbrev=False`) with a required, mutually exclusive `--check` / `--write` group. No mode, unknown arguments or abbreviations exit 2 without writing; `--help` exits 0 without writing. The `--check` path (silent on success, `stale fixtures: …` + exit 1) and the fixture table stay untouched. Proof: `--write` leaves `git status` clean and the fixture checksums identical. Update the docstring and `protocol/fixtures/README.md` to `--write`.
2. **`scripts/check.sh`:** parse `--only host|android|protocol` (repeatable, comma list, `--only=x` accepted; unknown component or argument exits 2). The component set is a plain string, not an array, because macOS `/bin/bash` 3.2 treats an empty array as unbound under `set -u`. No flag runs exactly today's steps in today's order with today's output. Under `--only`, probes are skipped. The CryptoKit vector diff runs only on Darwin and prints `SKIP (needs macOS)` elsewhere. The `JAVA_HOME`/`ANDROID_HOME` fallbacks stay guarded by "unset only".
3. **`.github/workflows/check.yml`:** triggers are push to `main` and `task/**`, plus `workflow_dispatch`, with `permissions: contents: read`. Concurrency cancels superseded runs on `task/**`, never on `main`. There are three jobs:
   - `changes` (ubuntu): a git-only path filter, because third-party filter actions are not allowed. On `main` it diffs `before..sha`, on `task/**` it diffs `merge-base(origin/main)..HEAD`. If the base is unknown (new branch, force push, dispatch), it runs everything.
   - `macos` (`macos-latest`, only when `host-mac/**`, `protocol/**`, `scripts/check.sh`, `.github/workflows/**` or `docs/PROTOCOL.md` changed): SwiftPM `.build` cache keyed on the toolchain version and `Package.*`, then `--only host` and `--only protocol` as separate steps.
   - `linux` (ubuntu, always): `fetch-depth: 0` so the T-146 versionCode is real, `actions/setup-java` Temurin 21 with `cache: gradle`, and `sdkmanager` installs `platforms;android-37.0`, `build-tools;36.0.0`, `ndk;30.0.16248370` and `cmake;4.1.2` (the same set as the owner's SDK). Then it runs `--only android` and `--only protocol`.
   - Every job has `timeout-minutes: 30`.
4. **Docs:**
   - 0022: add an explicit "CI'ın kapsamadığı" list (SCK, VT, `CGVirtualDisplay`, MediaCodec, AAudio, TCC, CGEvent posting, probes, device/instrumentation).
   - `docs/WORKFLOW.md`: one rule on the gate mechanics (push `task/*`, merge on green, advisory for the first week, then required).
   - `docs/PLAN.md:48`: drop "CI" from the deferred list and point to 0022.
5. **Verify:** run `check.sh` (all) and each `--only`, plus argument-error cases. Check gen.py modes and that the fixtures are byte-identical. Parse the YAML (Ruby Psych) and run actionlint if it can be fetched into the scratchpad without a global install.
- **Risks:** the hosted Xcode/SDK may differ from macOS 27, and timing tests may flake. Both only show up on a real run, and the advisory week covers them. A skipped `macos` job counts as success for a required check, which is intended for pure Android/docs pushes.

## Handoff

- **Commit:** `540bf18` (implementation), on top of `ffc168b` (plan). This Handoff is in the commit after them. Branch `task/T-149-ci-merge-gate`.
- **Dokunulan dosyalar:** `.github/workflows/check.yml` (new), `scripts/check.sh`, `protocol/fixtures/gen.py`, `protocol/fixtures/README.md`, `docs/WORKFLOW.md`, `docs/PLAN.md`, `docs/decisions/0022-ci-github-actions.md`, this card.
- **Verified locally (Mac, macOS 27, `/bin/bash` 3.2):**
  - **`check.sh` with no flag:** main's `check.sh` and this branch's ran back to back. Their step and result lists (`==>`, `OK`/`FAIL`, final line, exit code) are identical: 11 steps (host-mac + 2 Swift probes, client-android + 2 Gradle probes, fixtures, crypto), ALL OK, exit 0. Under `--only`, the run prints one extra line first, `check.sh: only …`.
  - **`--only`:**
    - `--only host`: only the host-mac build and test (OK). `--only android`: only gradle client-android (OK). `--only protocol`: fixtures, crypto and doc grep (OK).
    - With a fake `uname` that reports Linux, `--only=protocol` prints `SKIP (needs macOS): crypto vectors up to date` and exits 0.
    - `JAVA_HOME=/nonexistent-jdk … --only android` fails with Gradle's "JAVA_HOME is set to an invalid directory", so a set value is not overridden.
    - `--only` with nothing after it, `--only ''`, `--only ,`, an unknown component, or an unknown argument exits 2. `--help` exits 0.
    - New guard: under `--only`, a missing component (e.g. no `client-android/gradlew`) is a FAIL, so CI cannot go green by checking nothing. Without a flag, an empty tree stays ALL OK, as today.
  - **`gen.py`:**
    - No argument, `--chek`, `--wr`/`--ch` (abbreviations are off), `--check --write`, `foo`, and `--check foo` all exit 2. `--help` exits 0. None of these changed any fixture's mtime.
    - `--write` prints `wrote 48 fixtures`, and every file in `protocol/fixtures/` except `gen.py` itself has an identical SHA-1.
    - `--check` is silent with exit 0. With a fixture deliberately changed, it prints `stale fixtures: ['unknown_type'] …` and exits 1.
  - **Workflow:**
    - Parsed with Ruby Psych (3 jobs: `changes`, `macos`, `linux`).
    - `actionlint` 1.7.12 (release binary downloaded only into the scratchpad, checksum verified, not installed) reports 0 errors. Its shellcheck rule did not run because shellcheck is not installed.
    - Versions are the newest majors actionlint knows: `actions/checkout@v6`, `actions/setup-java@v5`, `actions/cache@v5`.
    - The `changes` step was extracted and run under `bash -e` in 6 contexts:
      - task branch with only the card changed: `mac=false`;
      - main with an all-zero `before`, or an unknown `before` SHA: `true`;
      - main with `before=HEAD~1` (card only): `false`;
      - main with `before=HEAD~30`: `true`;
      - `workflow_dispatch`: `true`.
- **Varsayımlar:**
  - The Android SDK on `ubuntu-latest` is under `$ANDROID_HOME` with `cmdline-tools/latest/bin/sdkmanager`. The package set is the owner's SDK (`platforms;android-37.0`, `build-tools;36.0.0`, `ndk;30.0.16248370`, `cmake;4.1.2`).
  - `macos-latest` has an Xcode with Swift ≥ 6.0 (`swift-tools-version: 6.0`, `.macOS(.v15)`). The host code needs no macOS 27 SDK API; the "macOS 27" mentions in the code are only measurement notes in comments.
  - A skipped `macos` job counts as success for a required check. That is intended for pure Android or docs pushes; the Linux job still runs `--only protocol`.
  - The "advisory week" ends on 2026-10-10 (WORKFLOW.md). Making CI required (branch protection or ruleset) is the orchestrator's or owner's step on GitHub; no file changes for it.
- **Test edilmeyenler (only a real GitHub run shows these):**
  - The first green run of both jobs (needs a push; run URLs are missing).
  - Whether the hosted macOS image's Xcode can build `host-mac`. If it cannot, the "revisit" clause in 0022 applies.
  - Whether the Linux `sdkmanager` step installs the packages, and whether AGP 9.4.1 + NDK + CMake build on Linux.
  - Whether timing-sensitive tests (`KeychainAsyncTests` 5 s, socket deadlines) flake on shared runners.
  - Job times with warm caches (< 15 min target).
  - The stale-fixture negative test.
  - Whether `concurrency.cancel-in-progress` behaves as expected for main and task branches.
  - On the first run, one `-dirty` versionName is possible if the Gradle build leaves an untracked file that is not gitignored. It does not affect the gate.
  - No hardware paths (SCK, VT, `CGVirtualDisplay`, MediaCodec, AAudio, TCC, CGEvent) are covered by CI; they are listed in 0022.
- **Orchestrator steps:**
  1. Push `task/T-149-ci-merge-gate` and check that `changes`, `macos` and `linux` are all green. This branch changes `.github/workflows/**`, so `macos` runs.
  2. For the negative test, on a throwaway branch `task/T-149-stale-fixture-probe`, add a comment line to one `protocol/fixtures/*.hex` and push. Both jobs' `--only protocol` step must fail. Add the run URL here, then delete the branch.
  3. After the merge, put the run URL and job times from main into this Handoff, and tick the three `[CI]` boxes.
- **Açık sorular:**
  - There is no Android SDK cache: the NDK (about 1–2 GB) is downloaded on every run. If the Linux job is slow, a follow-up card could add `actions/cache` for `$ANDROID_HOME/ndk/30.0.16248370`.
  - Should the Linux job also skip pure docs pushes? The card asks for the Linux job without a filter, so it was left unfiltered.
