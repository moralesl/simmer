# simmer -- claims on macOS wakefulness.
#
# Everything real lives in install.sh, so the same steps work without make and a
# remote one-liner stays possible. These are the names people try first.

PREFIX ?= $(HOME)/.local/bin

.PHONY: install check test diff uninstall icon workflow help

help:
	@echo "make install    link simmer into $(PREFIX), start the guard, build the notifier"
	@echo "make check      health report; expected to be fully green"
	@echo "make test       run the suite (claims nothing, needs no sudo)"
	@echo "make diff       differential: this implementation vs the v1.0.0 tag"
	@echo "make icon       regenerate assets/icon.icns from assets/icon.svg"
	@echo "make workflow   build the Alfred .alfredworkflow archive"
	@echo "make uninstall  remove the guard, the symlink and the notifier"

install: ; @PREFIX="$(PREFIX)" ./install.sh install
check:   ; @PREFIX="$(PREFIX)" ./install.sh check
uninstall: ; @PREFIX="$(PREFIX)" ./install.sh uninstall
icon:    ; @./install.sh icon
test:    ; @./test/simmer-test.sh

# Two suites, two jobs: `test` asks whether this implementation is internally
# right, `diff` asks whether it still agrees with the previous one. The second is
# the only one that catches a message or a field name drifting during a port,
# because that is the class of change where every individual test still passes.
diff:    ; @./test/differential.sh

# A .alfredworkflow is a zip with info.plist at its root. Built, never
# committed, so the archive cannot drift from the plist in git.
workflow:
	@rm -f integrations/alfred/Simmer.alfredworkflow
	@cd integrations/alfred/Simmer && zip -q -r ../Simmer.alfredworkflow . -x '.DS_Store'
	@echo "integrations/alfred/Simmer.alfredworkflow"
