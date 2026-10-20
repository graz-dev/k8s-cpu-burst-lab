# Run from the repository root: vhs capture/tapes/operator-status.tape
Output capture/out/operator-status.mp4
Output capture/out/operator-status.gif

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

Type "./lab.sh operator"
Enter
Wait+Screen@10m /results: /
Hide
Type "clear"
Enter
Show
Type "kubectl get sbp -n cpu-burst-demo -o wide"
Enter
Sleep 2s
Type "kubectl get sbp -n cpu-burst-demo -o jsonpath='{range .items[0].status.boostedPods[*]}{.name}{\"  \"}{.phase}{\"\\n\"}{end}'"
Enter
Wait+Screen@30s /Steady/
Sleep 2s
Screenshot capture/out/operator-status.png
