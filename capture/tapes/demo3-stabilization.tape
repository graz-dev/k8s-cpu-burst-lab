# Run from the repository root: vhs capture/tapes/demo3-stabilization.tape
Output capture/out/demo3-stabilization.mp4
Output capture/out/demo3-stabilization.gif

Set Shell "bash"
Set Width 1920
Set Height 1080
Set FontSize 30
Set Theme "Catppuccin Mocha"
Set Padding 30
Set TypingSpeed 35ms

# Quiet prompt, cleared screen, then start recording.
Hide
Type "export PS1='$ ' && clear"
Enter
Show

Type "./lab.sh stabilization"
Enter
Wait+Screen@30m /b_30s \|/
Sleep 8s
