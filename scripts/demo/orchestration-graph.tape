Output assets/demo/orchestration-graph.gif
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
Type 'DEMO_DIR="/tmp/demo-orch" && rm -rf "$DEMO_DIR" && eval "$(bash scripts/demo/fixture.sh "$DEMO_DIR")" && export PATH="$DEMO_DIR/bin:$PATH" COLUMNS=132 LINES=34 && cd "$DEMO_DIR" && export PS1="$ " && clear'
Enter
Sleep 800ms
Show

Sleep 300ms
Type "squad-orchestration.sh ws/.squad/workers"
Enter
Sleep 5s
Type "p"
Sleep 3s
Type "t"
Sleep 3s
Type "g"
Sleep 2s

Hide
Type "q"
Sleep 300ms
Type 'bash "$DEMO_DIR/cleanup.sh"'
Enter
