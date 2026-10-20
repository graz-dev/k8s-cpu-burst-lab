# Thin wrappers around ./lab.sh.
.PHONY: up down reset sidecar controller operator vpa compare manual-resize stabilization jvm-cpus watch results lint

up down reset sidecar controller operator vpa compare manual-resize stabilization jvm-cpus watch results:
	./lab.sh $@

lint:
	shellcheck lab.sh scripts/*.sh scripts/lib/*.sh scripts/scenarios/*.sh implementation-vpa/install-vpa.sh

capture-%: # TEMP-CAPTURE
	./lab.sh capture $*
