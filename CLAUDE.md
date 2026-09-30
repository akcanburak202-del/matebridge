@AGENTS.md

## Claude Code — orchestrator notes

The main session is the **orchestrator** (Opus). It owns: `docs/PROTOCOL.md`, `protocol/fixtures/`, `docs/decisions/`, backlog status, merges to `main`, pushes.

- **Delegation:** implementation tasks go to the project subagents in `.claude/agents/`: `mac-host-dev` and `android-client-dev` (Sonnet). Writing agents run with `isolation: "worktree"`. Read-only research and review agents may fan out more widely (see `docs/WORKFLOW.md` → Paralellik).
- **Task prompts** must include the card path and say "follow AGENTS.md". The card is the contract, and the prompt should not restate it.
- **Independent review:** run `./scripts/codex-review.sh main task/T-XXX-slug` for protocol, input-state, pen-injection and security changes. Codex uses `gpt-6.1-sol`. Effort is never below `medium` (the script sets it explicitly, because the CLI default may be `low`); pass `--high` for critical changes. Never use `gpt-6-astra` without user approval.
- **After merge:** set the card's `status: done`, then run `./scripts/board.sh` to regenerate `backlog/BOARD.md` and commit.
- **Device tests** (adb install, virtual display, TCC permissions) run one at a time, never from parallel agents.
- **Reporting to the user:** in Turkish, short, and end each step with a 3–5 item "tablette/Mac'te şunu dene" list when hardware testing is needed.
