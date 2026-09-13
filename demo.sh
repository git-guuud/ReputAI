#!/usr/bin/env bash
# The control room: four panes, three keys, one deployed name.
#
#   ./demo.sh          attach to the session (creates it if needed)
#   ./demo.sh --fresh  clear the transaction feed first, for a clean take
#   ./demo.sh --kill   tear the session down
#
# Left: the live chain state, which signs nothing and is nobody's. Right: one shell per party,
# each holding exactly one key. Which pane a transaction comes from is the argument.

set -euo pipefail
cd "$(dirname "$0")"

SESSION=${DEMO_SESSION:-reputai}
FEED=${DEMO_FEED:-deployments/.control-room.jsonl}

case "${1:-}" in
  --kill) tmux kill-session -t "$SESSION" 2>/dev/null || true; echo "gone"; exit 0 ;;
  --fresh) : > "$FEED" ;;
esac

attach() {
  if [ -t 0 ]; then exec tmux attach -t "$SESSION"; fi
  echo "session '$SESSION' is up — attach with: tmux attach -t $SESSION"
}

if tmux has-session -t "$SESSION" 2>/dev/null; then attach; exit 0; fi

# Explicit geometry: without a client attached tmux has no size to split, and the panes come out
# as one. A real attach resizes everything to the terminal anyway.
COLS=$(tput cols 2>/dev/null || echo 200)
ROWS=$(tput lines 2>/dev/null || echo 50)
tmux new-session -d -s "$SESSION" -x "$COLS" -y "$ROWS"

# Each pane's top border is a full-width bar in that actor's colour, carrying its name and the
# verbs it may type. Thin borders in one grey read as a single merged surface, which is the
# opposite of the point: a viewer should be able to tell whose key is whose before reading a
# word of output, and the presenter should never need to look up a verb.
#
# `pane-border-format` is a window option, so the colour cannot be written into it per pane.
# It comes from `@bar`, a per-pane user option set below — one format, four colours.
tmux set-option -t "$SESSION" pane-border-lines heavy
tmux set-option -t "$SESSION" pane-border-status top
tmux set-option -t "$SESSION" pane-border-format "#[bg=#{@bar},fg=#0c0e12,bold]#{p300:pane_title}"
tmux set-option -t "$SESSION" status off
tmux set-option -t "$SESSION" mouse on

# Colours come from the CLI so the border, the header bar inside the pane and every line that
# actor signs are one palette with one source.
colour_of() { node -e "import('./cli/lib/ui.mjs').then(u=>process.stdout.write(u.tmuxColour('$1')))"; }
CONTROL=$(colour_of control)
OPERATOR=$(colour_of operator)
AGENT=$(colour_of agent)
COUNTERPARTY=$(colour_of counterparty)

pane() { # pane <colour> <title>
  tmux set-option -p -t "$SESSION" @bar "$1"
  tmux select-pane -t "$SESSION" -T " $2"
}

tmux send-keys -t "$SESSION" "node cli/reput.mjs watch" C-m
pane "$CONTROL" "CONTROL ROOM   live chain state · holds no key · signs nothing"

# The control room is the wider half: it carries the whole argument, and the shells only ever
# show one action at a time.
tmux split-window -h -t "$SESSION" -l 40%
tmux send-keys -t "$SESSION" "node cli/reput.mjs operator" C-m
pane "$OPERATOR" "OPERATOR   provision · freeze · unfreeze · revoke"

tmux split-window -v -t "$SESSION" -l 66%
tmux send-keys -t "$SESSION" "node cli/reput.mjs agent" C-m
pane "$AGENT" "AGENT   publish · rotate · escape"

tmux split-window -v -t "$SESSION" -l 50%
tmux send-keys -t "$SESSION" "node cli/reput.mjs counterparty" C-m
pane "$COUNTERPARTY" "COUNTERPARTY   check · pay · pay retired"

tmux select-pane -t "$SESSION".1
attach
