# Run from the repository root: vhs capture/tapes/demo1-compare.tape
Output "capture/out/demo1-compare.mp4"
Output "capture/out/demo1-compare.gif"

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

# compare --parallel runs in the background; the table shows the three Pods.
Hide
Type "(./lab.sh compare --parallel > /dev/null 2>&1 &)"
Enter
Show
Type "./lab.sh watch cpu-burst-compare"
Enter
# The boost Pod is done when its actual CPU reads 300m.
Wait+Screen@10m /petclinic-boost\S+\s+Running\s+true\s+300m\s+300m/
Sleep 8s
