# Run from the repository root: vhs capture/tapes/demo2-manual-resize.tape
Output "capture/out/demo2-manual-resize.mp4"
Output "capture/out/demo2-manual-resize.gif"

Set Shell "bash"
Set Width 1920
Set Height 1080
Set FontSize 24
Set Theme "Catppuccin Mocha"
Set Padding 30
Set TypingSpeed 35ms

# Quiet prompt, cleared screen, then start recording.
Hide
Type "export PS1='$ ' && clear"
Enter
Show

Type "./lab.sh manual-resize; echo DO''NE"
Enter
Wait+Screen@10m /DONE/
Sleep 8s
