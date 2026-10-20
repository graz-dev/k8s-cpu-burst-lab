#!/usr/bin/env bash
# Split terminal for the demo 3 recording: the Pod table, the policy phases and
# the narrated scenario, stacked. Run from the repository root, inside the VHS tape.
set -euo pipefail
S=demo3
NS=cpu-burst-stabilization
tmux kill-session -t "${S}" 2>/dev/null || true

PHASES='while :; do clear; echo "StartupBoostPolicy"; kubectl get startupboostpolicies -n '"${NS}"' -o custom-columns=POLICY:.metadata.name,STABILIZATION:.spec.stabilizationSeconds,POD:.status.boostedPods[*].name,PHASE:.status.boostedPods[*].phase,MESSAGE:.status.boostedPods[*].message 2>/dev/null; sleep 1; done'

tmux new-session -d -s "${S}" -x "$(tput cols)" -y "$(tput lines)" "./lab.sh watch ${NS}"
tmux set-option -t "${S}" status off
tmux set-option -t "${S}" pane-border-style fg=colour240
tmux split-window -v -t "${S}" "bash -c '${PHASES}'"
tmux split-window -v -t "${S}" "bash -c './lab.sh stabilization; echo FIN''ISHED; sleep 3600'"
tmux resize-pane -t "${S}:0.0" -y 6
tmux resize-pane -t "${S}:0.1" -y 6
tmux select-pane -t "${S}:0.2"
exec tmux attach -t "${S}"
