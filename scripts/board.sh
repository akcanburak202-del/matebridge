#!/usr/bin/env bash
# Regenerates backlog/BOARD.md from task-card frontmatter. Do not edit BOARD.md by hand.
set -euo pipefail
cd "$(dirname "$0")/.."

field() { # field <name> <file>
  sed -n '/^---$/,/^---$/p' "$2" | grep -m1 "^$1:" | sed -E "s/^$1:[[:space:]]*//; s/[[:space:]]+#.*$//"
}

{
  echo "# Board"
  echo
  echo "_Otomatik üretildi: \`./scripts/board.sh\` — elle düzenleme._"
  for status in in-progress review blocked todo done; do
    rows=""
    for f in backlog/tasks/T-*.md; do
      [ -e "$f" ] || continue
      [ "$(field status "$f")" = "$status" ] || continue
      rows+="| [$(field id "$f")]($(basename "$f")) | $(field title "$f") | $(field phase "$f") | $(field owner "$f") | $(field depends_on "$f") |"$'\n'
    done
    [ -n "$rows" ] || continue
    echo
    echo "## $status"
    echo
    echo "| ID | Başlık | Aşama | Sahip | Bağımlılık |"
    echo "|---|---|---|---|---|"
    printf "%s" "$rows"
  done
} > backlog/BOARD.md.tmp
# Links in BOARD.md are relative to backlog/, tasks live in backlog/tasks/
sed -E 's/\]\((T-[^)]+)\)/](tasks\/\1)/' backlog/BOARD.md.tmp > backlog/BOARD.md
rm backlog/BOARD.md.tmp
echo "backlog/BOARD.md updated"
