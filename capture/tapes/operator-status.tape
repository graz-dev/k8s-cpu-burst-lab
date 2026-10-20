# Run from the repository root: vhs capture/tapes/operator-status.tape
Output "capture/out/operator-status.mp4"
Output "capture/out/operator-status.gif"

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

Type "./lab.sh operator; echo DO''NE"
Enter
Wait+Screen@10m /DONE/
Hide
Type "clear"
Enter
Show
Type "kubectl get sbp -n cpu-burst-demo -o wide"
Enter
Sleep 2s
Type "kubectl get sbp -n cpu-burst-demo -o custom-columns=POLICY:.metadata.name,POD:.status.boostedPods[*].name,PHASE:.status.boostedPods[*].phase"
Enter
Wait+Screen@60s /Steady/
Sleep 2s
Screenshot "capture/out/operator-status.png"

Sleep 1s
