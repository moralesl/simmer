# simmer — build, test, bundle, install.
#
# CLT-only by design: the bundle is hand-assembled and ad-hoc signed, never
# xcodebuild. Colleagues' machines have at best the Command Line Tools, and
# the build must work exactly there (PLATFORM-FACTS.md).

PREFIX       ?= $(HOME)/Applications
# THE production id, promoted for the Swift rewrite. macOS caches a notification
# permission verdict per bundle id FOREVER and a denial can never be undone
# (PLATFORM-FACTS.md § 1), so this line is a one-way door: never point it at a
# fresh id to "test something", and never let a test bundle ask for permission
# under it.
#
# Ids spent on the maintainer's Mac, and therefore unusable:
#   .dev   — denied on first install
#   .dev2  — the id the rewrite was developed under
# Development after this point uses .dev3 (make BUNDLE_ID=…dev3 app), which is
# then spent too. There is no supply problem; there is no recovery either.
BUNDLE_ID    ?= io.github.moralesl.simmer
GUARD_LABEL   = io.github.moralesl.simmer.guard
# Single-sourced from SimmerCore — the CLI, the app and this plist must agree.
VERSION      := $(shell sed -n 's/.*string = "\(.*\)".*/\1/p' Sources/SimmerCore/Version.swift)
APP           = $(PREFIX)/Simmer.app
BUILD         = .build/release
STAGED_APP    = .build/Simmer.app
LSREGISTER    = /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
AGENT_PLIST   = $(HOME)/Library/LaunchAgents/$(GUARD_LABEL).plist
# The ledger's location, resolved HERE and baked into the LaunchAgent, because
# launchd hands an agent none of the installing shell's environment. Someone
# who exports XDG_STATE_HOME otherwise gets a guard reading a different ledger
# than their CLI writes, and the two settle one switch against each other
# forever. Same default as SimmerEnvironment.stateDir — keep them in step.
STATE_HOME   ?= $(if $(XDG_STATE_HOME),$(XDG_STATE_HOME),$(HOME)/.local/state)
BIN_DIR      ?= $(HOME)/.local/bin
# Where a Claude Code agent looks for skills. The protocol an agent needs is the
# first half of AGENTS.md, so the skill is GENERATED from it rather than kept as
# a second copy: a copy drifts, and the only person who would notice is the
# agent reading the stale one. AGENTS.md is already a fixture (AgentDocTests),
# so the skill inherits that check for free.
SKILL_DIR    ?= $(HOME)/.claude/skills/simmer
SKILL_DESC    = Claim awake time before long unattended work on this Mac, so the lid closing cannot interrupt it. Use before any batch, build, eval, migration or agent run measured in tens of minutes, and whenever `simmer` is on PATH.

# A CLT-only toolchain ships Testing.framework outside the default search
# paths; swift test finds nothing without these.
#
# Applied only when the CLT is the SELECTED toolchain, not merely present. The
# old condition was existence alone, with a comment claiming it was "harmless
# under full Xcode" — it is not. With an Xcode selected and the CLT also
# installed, these flags make the compiler's output link a DIFFERENT copy of
# Testing.framework than it compiled against, which is an undefined-symbol
# link failure ("Testing.__requiringUnsafe", "__TestContentRecordContainer").
# It stayed hidden because the maintainer's Mac has no Xcode at all, so both
# sides were always the CLT; CI selecting the newest Xcode is what surfaced it.
#
# `xcode-select -p` honours DEVELOPER_DIR, so overriding that for one command
# switches this correctly too.
CLT_DEVELOPER_DIR = /Library/Developer/CommandLineTools
CLT_FRAMEWORKS = $(CLT_DEVELOPER_DIR)/Library/Developer/Frameworks
CLT_TESTLIB    = $(CLT_DEVELOPER_DIR)/Library/Developer/usr/lib
SELECTED_DEVELOPER_DIR := $(shell xcode-select -p 2>/dev/null)
ifeq ($(SELECTED_DEVELOPER_DIR),$(CLT_DEVELOPER_DIR))
ifneq ($(wildcard $(CLT_FRAMEWORKS)/Testing.framework),)
TEST_FLAGS = -Xswiftc -F -Xswiftc $(CLT_FRAMEWORKS) \
             -Xlinker -F -Xlinker $(CLT_FRAMEWORKS) \
             -Xlinker -rpath -Xlinker $(CLT_FRAMEWORKS) \
             -Xlinker -rpath -Xlinker $(CLT_TESTLIB)
endif
endif

.PHONY: build test test-raycast skill app install uninstall clean

build:
	swift build -c release

test:
	swift test $(TEST_FLAGS)

# `swift test` knows nothing about integrations/raycast, so a change to the
# extension that runs only `make test` is untested and looks green — the
# extension is a second toolchain with its own tree, and the one documented
# test command could not reach it. This is CI's `raycast-lint` leg, locally.
#
# Deliberately NOT folded into `test`: that target is hermetic and finishes in
# seconds, and making it depend on an npm install would cost every Swift change
# the extension's setup. Two lanes, both named.
test-raycast:
	# `npm ci` deletes node_modules and reinstalls from the lockfile, which is
	# right on a fresh checkout and pure waste on the fifth run of the day.
	cd integrations/raycast && { [ -d node_modules ] || npm ci; } \
	  && npm run typecheck && npx eslint src tests && npm test

# Assemble the bundle: both binaries inside Contents/MacOS — the bundle IS the
# notification identity, and the CLI posting from inside it is what lets a
# guard tick carry simmer's own icon.
# Quiet recipes: a non-technical colleague reads raw command echo as errors.
# The human-facing lines below are the output; `make V=1 …` shows the commands.
ifndef V
.SILENT:
endif

# Render the agent protocol as a Claude Code skill. Extracted between the two
# top-level headings, so the contributor half of AGENTS.md never reaches an
# agent that has no checkout and no use for iron rules.
#
# The `---` filter drops the page's section separators; markdown tables start
# with `|`, so no table rule is caught by it.
skill:
	mkdir -p $(SKILL_DIR)
	{ \
	  echo '---'; \
	  echo 'name: simmer'; \
	  printf 'description: "%s"\n' '$(SKILL_DESC)'; \
	  echo '---'; \
	  echo ''; \
	  echo '<!-- simmer-protocol version=$(VERSION) source=AGENTS.md -->'; \
	  echo '<!-- generated by `make skill` — edit AGENTS.md, not this file -->'; \
	  echo ''; \
	  awk '/^# Using simmer$$/{f=1} /^# Changing simmer$$/{f=0} f' AGENTS.md \
	    | grep -v '^---$$'; \
	} > $(SKILL_DIR)/.SKILL.md.tmp
	# Written aside and moved into place: a redirect onto the destination
	# truncates it the moment any stage of the pipeline fails, and a half-written
	# protocol is worse than a stale one — it is a stale one that also lies about
	# being complete. The ledger takes the same care, for the same reason.
	mv $(SKILL_DIR)/.SKILL.md.tmp $(SKILL_DIR)/SKILL.md
	echo "skill:     $(SKILL_DIR)/SKILL.md  (generated from AGENTS.md)"

app: build
	rm -rf $(STAGED_APP)
	mkdir -p $(STAGED_APP)/Contents/MacOS $(STAGED_APP)/Contents/Resources
	# @STATE_HOME@ for the same reason the LaunchAgent gets it: an app
	# launched from the Dock inherits none of the shell's environment, so a
	# shell exporting XDG_STATE_HOME put the app on one ledger and the CLI
	# on another — the guard's bug, in the other half of the bundle.
	sed -e 's/@BUNDLE_ID@/$(BUNDLE_ID)/g' -e 's/@VERSION@/$(VERSION)/g' \
	    -e 's|@STATE_HOME@|$(STATE_HOME)|g' \
	    app/Info.plist.template > $(STAGED_APP)/Contents/Info.plist
	# The app executable is NOT named "Simmer": APFS is case-insensitive,
	# so "Simmer" and the CLI "simmer" would silently be the same file.
	cp $(BUILD)/simmer-app $(STAGED_APP)/Contents/MacOS/simmer-app
	cp $(BUILD)/simmer $(STAGED_APP)/Contents/MacOS/simmer
	cp assets/icon.icns $(STAGED_APP)/Contents/Resources/icon.icns
	codesign --force --deep --sign - $(STAGED_APP) 2>/dev/null
	echo "assembled and ad-hoc signed: $(STAGED_APP) ($(BUNDLE_ID))"

install: app
	mkdir -p $(PREFIX) $(BIN_DIR)
	# Unregister whatever bundle id the outgoing app carried BEFORE deleting
	# it — a registration that outlives its bundle is exactly the stale-entry
	# ghost PLATFORM-FACTS documents.
	[ -d $(APP) ] && $(LSREGISTER) -u $(APP) || true
	rm -rf $(APP)
	cp -R $(STAGED_APP) $(APP)
	$(LSREGISTER) -f $(APP)
	ln -sf $(APP)/Contents/MacOS/simmer $(BIN_DIR)/simmer
	mkdir -p $(HOME)/Library/LaunchAgents
	sed -e 's|@CLI@|$(APP)/Contents/MacOS/simmer|g' \
	    -e 's|@LABEL@|$(GUARD_LABEL)|g' \
	    -e 's|@STATE_HOME@|$(STATE_HOME)|g' \
	    launchd/guard.plist.template > $(AGENT_PLIST)
	# bootout returns before the job is gone — poll until it is
	launchctl bootout gui/$$(id -u)/$(GUARD_LABEL) 2>/dev/null || true
	i=0; while launchctl print gui/$$(id -u)/$(GUARD_LABEL) >/dev/null 2>&1; do \
	    i=$$((i+1)); [ $$i -gt 50 ] && break; sleep 0.1; done
	launchctl bootstrap gui/$$(id -u) $(AGENT_PLIST)
	echo "installed: $(APP)  (bundle id $(BUNDLE_ID))"
	echo "CLI:       $(BIN_DIR)/simmer  — make sure $(BIN_DIR) is on PATH"
	echo "guard:     $(GUARD_LABEL), every 30s and at login"
	# The protocol has to reach the agents that use simmer, and they are never
	# in this checkout — they are in some other repository on this Mac. A page
	# nobody installs is a page nobody reads, so install it where an agent
	# already looks. Only where Claude Code is already set up: creating
	# ~/.claude on a machine that does not use it would be litter.
	# `|| true` here would absorb a real generator failure along with the
	# absent-directory case, so the test gets its own branch and a broken
	# `make skill` still fails the install.
	if [ -d $(HOME)/.claude ]; then $(MAKE) --no-print-directory skill; fi
	# NOTES=0 (bootstrap.sh passes it) suppresses the what-remains epilogue —
	# bootstrap performs both steps itself right after this, and telling a
	# person to do what the next paragraph is about to do reads as a bug.
	[ "$(NOTES)" = "0" ] || { \
	    echo ""; \
	    echo "Two steps remain, both yours (they need a human):"; \
	    echo "  1. The sudo rule — bootstrap.sh installs it, or run it yourself:"; \
	    echo "       simmer doctor   # says whether it is in place, and prints the command"; \
	    echo "  2. open -a Simmer, then click Allow on the notification banner."; }

# Hand the machine back BEFORE removing anything, and refuse to go on if that
# did not work.
#
# This recipe deletes the guard, the app, and the CLI binary the ~/.local/bin
# symlink points at — every mechanism on the Mac that can put the sleep switch
# back. Run with a claim live it used to leave `pmset -a disablesleep 1` on,
# which per PLATFORM-FACTS.md has no expiry, shows no indicator and survives
# reboots; SECURITY.md names that exact state as the vulnerability, and the
# recovery command appeared in neither the README nor the FAQ.
#
# SIMMER_HUMAN=1 because a person typed this. `down --all` is a human's
# authority and make has no tty for simmer to notice one.
uninstall:
	@# WHICH simmer, and WHICH app — from the LaunchAgent, not from this
	@# invocation's variables. The gates used to hang off $(BIN_DIR)/simmer, so
	@# an install done with a different BIN_DIR or PREFIX made both of them
	@# silently untrue while the removals below — which use fixed paths — ran
	@# anyway. The plist sits at a fixed path and records what was actually
	@# installed, so it is the thing that knows.
	@# And the seam: `status` prints `seamed=1` when a SIMMER_FAKE_* variable
	@# is in the environment, which is exactly the leaked-export case that
	@# field exists for. A gate that reads `sleep_disabled` and ignores
	@# `seamed` is reading a file in /tmp and calling it the machine.
	@set -e; \
	 CLI=$$(/usr/libexec/PlistBuddy -c "Print :ProgramArguments:0" $(AGENT_PLIST) 2>/dev/null || true); \
	 [ -x "$$CLI" ] || CLI=$(BIN_DIR)/simmer; \
	 if [ ! -x "$$CLI" ]; then \
	   echo "simmer: no installed simmer binary found, so this cannot check whether"; \
	   echo "        the Mac is still being held awake — and removing the guard"; \
	   echo "        would take away the thing that would have handed it back."; \
	   echo ""; \
	   echo "            sudo pmset -a disablesleep 0     # revert it by hand"; \
	   echo "            make uninstall FORCE=1           # remove anyway"; \
	   [ -n "$(FORCE)" ] || exit 1; \
	 else \
	   SIMMER_HUMAN=1 env -u SIMMER_FAKE_PMSET -u SIMMER_FAKE_BATTERY \
	     -u SIMMER_FAKE_BATTERY_TIME -u SIMMER_FAKE_NOW -u SIMMER_FAKE_THERMAL \
	     -u SIMMER_FAKE_LOCKDELAY "$$CLI" down --all || true; \
	   STATE=$$(env -u SIMMER_FAKE_PMSET -u SIMMER_FAKE_BATTERY \
	     -u SIMMER_FAKE_BATTERY_TIME -u SIMMER_FAKE_NOW -u SIMMER_FAKE_THERMAL \
	     -u SIMMER_FAKE_LOCKDELAY "$$CLI" status --machine || true); \
	   if ! printf '%s\n' "$$STATE" | grep -q '^sleep_disabled=0' \
	      || ! printf '%s\n' "$$STATE" | grep -q '^seamed=0'; then \
	     echo "simmer: this Mac is still being held awake, and uninstalling removes"; \
	     echo "        the only thing here that can stop that. Put it back first:"; \
	     echo ""; \
	     echo "            sudo pmset -a disablesleep 0"; \
	     echo ""; \
	     echo "        then run 'make uninstall' again, or 'make uninstall FORCE=1'"; \
	     echo "        to remove simmer anyway and revert the switch by hand."; \
	     [ -n "$(FORCE)" ] || exit 1; \
	   fi; \
	 fi
	-launchctl bootout gui/$$(id -u)/$(GUARD_LABEL) 2>/dev/null
	rm -f $(AGENT_PLIST)
	@# Only the app can unregister its own login item (SMAppService is
	@# bundle-scoped, like the notification grant), so ask it before the
	@# bundle goes — otherwise System Settings keeps listing a login item
	@# pointing at an app that no longer exists.
	-[ -x $(APP)/Contents/MacOS/simmer-app ] && $(APP)/Contents/MacOS/simmer-app --uninstall
	@# Quit it, and CHECK. A running Simmer.app outlives the files it was
	@# launched from, keeps its menu bar, and one click on "Stay awake for…"
	@# re-arms disablesleep with the guard already gone. The quit is an
	@# AppleEvent, which TCC can refuse silently and which fails in any
	@# non-interactive context — so `-osascript … 2>/dev/null` on its own was
	@# a hope, not a step. Verified the way `install` verifies its bootout.
	@-osascript -e 'tell application id "$(BUNDLE_ID)" to quit' 2>/dev/null || true
	@for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -qx simmer-app || break; sleep 0.3; done; \
	 if pgrep -qx simmer-app; then \
	   echo "simmer: Simmer.app is still running and would outlive its own bundle —"; \
	   echo "        its menu bar keeps working and one click re-arms the switch."; \
	   echo "        Quit it from the menu bar, then run this again."; \
	   [ -n "$(FORCE)" ] || exit 1; \
	 fi
	-[ -d $(APP) ] && $(LSREGISTER) -u $(APP)
	rm -rf $(APP)
	rm -f $(BIN_DIR)/simmer
	rm -rf $(SKILL_DIR)
	@echo "Removed the app, the CLI symlink, the guard and the agent skill."
	@echo "Left alone if present (needs root, and only if simmer wrote it):"
	@echo "  /etc/sudoers.d/simmer — remove with: sudo rm /etc/sudoers.d/simmer"
	@echo "If sleep still does not work, the switch is the last thing to revert:"
	@echo "  sudo pmset -a disablesleep 0"

clean:
	swift package clean
	rm -rf $(STAGED_APP)
