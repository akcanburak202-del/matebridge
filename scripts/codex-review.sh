#!/usr/bin/env bash
# Independent read-only review by Codex (different model family = different blind spots).
# Usage: ./scripts/codex-review.sh [--high] <base-branch | --commit SHA | --uncommitted>
#   --high  raise reasoning effort for critical changes (protocol, input state, security)
# Model is fixed to gpt-6-sol. gpt-6-astra requires explicit user approval (docs/WORKFLOW.md).
set -euo pipefail
cd "$(dirname "$0")/.."

args=(-m gpt-6-sol)
if [ "${1:-}" = "--high" ]; then args+=(-c 'model_reasoning_effort="high"'); shift; fi

case "${1:-}" in
  "") echo "usage: $0 [--high] <base-branch | --commit SHA | --uncommitted>" >&2; exit 2 ;;
  --uncommitted) args+=(--uncommitted) ;;
  --commit) args+=(--commit "${2:?commit SHA required}") ;;
  *) args+=(--base "$1") ;;
esac

prompt="Review per AGENTS.md hard rules. Focus: Swift/Kotlin protocol consistency, lost key/button/pen up events, unbounded queues, threading, resource cleanup, text/character logging. Report findings by severity with file:line and a concrete failure scenario. Do not modify files."

codex exec review "${args[@]}" "$prompt"
