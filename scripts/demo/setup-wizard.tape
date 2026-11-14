Output assets/demo/setup-wizard.gif
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
Type 'DEMO_DIR="/tmp/demo-setup" && rm -rf "$DEMO_DIR" && eval "$(bash scripts/demo/fixture.sh --fake-clis "$DEMO_DIR")" && export COLUMNS=132 LINES=34 PS1="$ " && clear'
Enter
Sleep 600ms
Show

Sleep 400ms
Type "squad-devkit --setup"
Enter
Sleep 1.8s
Type "2"
Enter
Sleep 1.2s
Type "1"
Enter
Sleep 1.2s
Type "agy,opencode"
Enter
Sleep 1.5s
Type "y"
Enter
Sleep 2.5s

Hide
Type 'rm -rf "$DEMO_DIR"'
Enter
