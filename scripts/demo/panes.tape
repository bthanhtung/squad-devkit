Output assets/demo/panes.gif
Set Shell "bash"
Set Width 1100
Set Height 650
Set FontSize 14
Set Padding 12
Set Theme "Catppuccin Mocha"
Set TypingSpeed 40ms
Env PS1 "$ "
Env COLUMNS "132"
Env LINES "34"
Env BASH_SILENCE_DEPRECATION_WARNING "1"

Hide
Type 'DEMO_DIR="/tmp/demo-panes" && rm -rf "$DEMO_DIR" && eval "$(bash scripts/demo/fixture.sh "$DEMO_DIR")" && export PATH="$DEMO_DIR/bin:$PATH" COLUMNS=132 LINES=34 && cd "$DEMO_DIR" && tmux -L demo-panes -f /dev/null new-session -d -s demo -x 132 -y 34 "$DEMO_DIR/manager-pane.sh" && tmux -L demo-panes set-option -t demo status-left "[squad] " && tmux -L demo-panes set-option -t demo status-right "panes view " && tmux -L demo-panes split-window -h -p 54 -t demo:0.0 "COLUMNS=70 LINES=16 squad-worker-monitor.sh ws/.squad/workers/dev-1.status" && tmux -L demo-panes split-window -v -p 50 -t demo:0.1 "COLUMNS=70 LINES=16 squad-worker-monitor.sh ws/.squad/workers/dev-2-2.status" && tmux -L demo-panes select-pane -t demo:0.0 && export PS1="$ " && clear'
Enter
Sleep 1s
Show

Sleep 300ms
Type "tmux -L demo-panes attach -t demo"
Enter
Sleep 5.5s

Hide
Ctrl+b
Type "d"
Sleep 300ms
Type 'bash "$DEMO_DIR/cleanup.sh"; tmux -L demo-panes kill-server 2>/dev/null'
Enter
