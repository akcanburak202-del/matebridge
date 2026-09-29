# AGENTS.md — MateBridge

Shared instructions for every coding agent (Claude, Codex, others). Keep this file short. Area-specific rules live in `host-mac/AGENTS.md` and `client-android/AGENTS.md`.

## What this project is

MateBridge turns a Huawei MatePad Pro 12.2 (2025, HarmonyOS 4.3, Android APKs, no Google Play) into a LAN display plus input terminal for a Mac mini (Apple M6, macOS 27):

- **Display:** the Mac creates a virtual display at the tablet's native 2800×1840 resolution, then ScreenCaptureKit → VideoToolbox → network → MediaCodec.
- **Input:** tablet → network → CGEvent. Covers the M-Pencil with pressure and tilt (the core differentiator), keyboard, trackpad and touch.

Plan: `docs/PLAN.md`. Process: `docs/WORKFLOW.md`. Wire format: `docs/PROTOCOL.md`.

## Before you write code

1. You must have a task card: `backlog/tasks/T-XXX-*.md`. No card, no code.
2. Read the card, its `depends_on` tasks, and any decision it references in `docs/decisions/`.
3. Touch **only** the files and directories listed under `files:` in the card. If you need more, stop and write the reason in the card's *Open questions*.
4. If the card's *Plan* section is empty, write the plan first, commit it, then implement.

## Hard rules

- **Protocol drift is the #1 risk.** Swift and Kotlin must agree byte-for-byte. Any change to messages means updating `docs/PROTOCOL.md` and the golden vectors in `protocol/fixtures/`, and both sides must pass the fixture tests. Only the orchestrator changes the protocol.
- **Input state must never get stuck.** On disconnect, background, or device detach, release every held key, button and pen contact. Never drop a key-up, button-up or pen-up event.
- **Bounded queues only.** For video frames the newest frame wins, and stale frames are dropped.
- **Privacy.** Never log key characters or text. Keycodes may be logged only at `debug` level. Never commit logs, device serial numbers, or personal data.
- **Private API** (`CGVirtualDisplay`) is isolated behind one Swift file/type, `VirtualDisplay`. Nothing else touches it.
- Do not add dependencies without a decision record (`docs/decisions/`).

## Verify before handoff

```bash
./scripts/check.sh        # builds + tests everything that exists; must pass
```

Then fill in the card's **Handoff** section: commit SHA, files touched, assumptions, what was NOT tested (especially anything needing the real tablet), and open questions.

## Conventions

- Language: code, identifiers, comments and commit messages in **English**. Planning docs and task cards are in **Turkish**. Either language is fine inside cards.
- Commits: `T-XXX: imperative summary`. Keep them small, and one task per branch (`task/T-XXX-slug`).
- Runtime logging format: `docs/LOGGING.md`.
- Hardware findings go in `docs/NOTES.md` (append, dated). Decisions go in `docs/decisions/`, never only in chat.

## Do not

- Edit `docs/archive/`, `LICENSE`, or other agents' in-progress task cards.
- Push, force-push, rewrite history, or merge to `main`. Only the orchestrator merges.
- "Fix" unrelated code you notice. Note it under *Open questions* instead.
