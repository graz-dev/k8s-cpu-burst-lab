# Run from the repository root: vhs capture/tapes/demo3-stabilization.tape
# The whole run (about 6 minutes) is played at 4x speed.
Output "capture/out/demo3-stabilization.mp4"
Output "capture/out/demo3-stabilization.gif"

Set Shell "bash"
Set Width 1920
Set Height 1080
Set FontSize 22
Set Theme "Catppuccin Mocha"
Set Padding 20
Set TypingSpeed 35ms
Set PlaybackSpeed 4

Hide
Type "export PS1='$ ' && clear"
Enter
Show

Type "./capture/demo3-layout.sh"
Enter
Wait+Screen@40m /FINISHED/
Sleep 30s
