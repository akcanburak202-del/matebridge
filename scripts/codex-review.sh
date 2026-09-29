#!/usr/bin/env bash
# Independent read-only review by Codex (different model family = different blind spots).
# Usage: ./scripts/codex-review.sh [--high] <base> [head]      review git diff base...head (head defaults to HEAD)
#        ./scripts/codex-review.sh [--high] --commit SHA | --uncommitted
#   --high  raise reasoning effort for critical changes (protocol, input state, security)
# Example (task branch, run from main checkout): ./scripts/codex-review.sh main task/T-005-pen-sink-probe
# Model is fixed to gpt-6-sol. gpt-6-astra requires explicit user approval (docs/WORKFLOW.md).
#
# `codex exec review` presets (--base/--commit/--uncommitted) reject a custom prompt, so the
# branch/commit forms use plain `codex exec` in a read-only sandbox with the diff range in the prompt.
set -euo pipefail
cd "$(dirname "$0")/.."

args=(-m gpt-6-sol -s read-only)
if [ "${1:-}" = "--high" ]; then args+=(-c 'model_reasoning_effort="high"'); shift; fi

focus="Review per AGENTS.md hard rules and the task card(s) touched by the diff. Focus: Swift/Kotlin protocol consistency, lost key/button/pen up events, unbounded queues, threading, resource cleanup, text/character logging. Report findings by severity with file:line and a concrete failure scenario. Do not modify files."

case "${1:-}" in
  "") echo "usage: $0 [--high] <base> [head] | --commit SHA | --uncommitted" >&2; exit 2 ;;
  --uncommitted) range="the uncommitted changes (git diff HEAD, plus untracked files from git status)" ;;
  --commit) sha="${2:?commit SHA required}"; git rev-parse --verify -q "$sha^{commit}" >/dev/null
            range="the changes introduced by commit $sha (git show $sha)" ;;
  *) base=$1 head=${2:-HEAD}
     git rev-parse --verify -q "$base^{commit}" >/dev/null || { echo "unknown base: $base" >&2; exit 2; }
     git rev-parse --verify -q "$head^{commit}" >/dev/null || { echo "unknown head: $head" >&2; exit 2; }
     [ -n "$(git diff --name-only "$base...$head")" ] || { echo "empty diff: $base...$head" >&2; exit 2; }
     range="the changes in git diff $base...$head (read files at $head with git show $head:<path>)" ;;
esac

codex exec "${args[@]}" "Review $range. $focus"
