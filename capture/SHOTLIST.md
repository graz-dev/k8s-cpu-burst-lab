# Shot list

One row per asset. Output goes to `capture/out/` (gitignored).
Run an asset with `./lab.sh capture <asset>` or `make capture-<asset>`.

Setup once: `./capture/setup.sh` (Playwright and Chromium in `capture/out/venv`).
VHS tapes need [vhs](https://github.com/charmbracelet/vhs) on the PATH (`brew install vhs`).

| Slide | Asset | What it must show | Command | Status |
|---|---|---|---|---|
| Demo 1 | `demo1-compare.mp4` | Three Pods, time to Ready, throttling, RESTARTS 0 for boost | `./lab.sh capture demo1-compare` (VHS + `compare --parallel`) | todo |
| Demo 2 | `demo2-manual-resize.mp4` | `cpu.max` before and after, conditions, restartCount 0 | `./lab.sh capture demo2-manual-resize` (VHS + `manual-resize`) | todo |
| Timing | `stabilization-0.png`, `stabilization-30.png` | CPU, limit and throttling ratio around the resize, same scale | `./lab.sh capture stabilization-png` (Grafana, `stabilization` runs A and B) | todo |
| Timing / JVM | numbers | Throttling and p95 with vs without `ActiveProcessorCount` | `./lab.sh capture numbers` (after `./lab.sh jvm-cpus`) | todo |
| Operator | `operator-status.png` | `kubectl get sbp` and the status phases | `./lab.sh capture operator-status` (VHS screenshot) | todo |
| Demo 3 | `demo3-stabilization.mp4` | Runs A and B with load | `./lab.sh capture demo3-stabilization` (VHS + `stabilization`) | todo |
