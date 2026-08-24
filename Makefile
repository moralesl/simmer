# simmer v1 — build, test, bundle, install.
#
# CLT-only by design: the bundle is hand-assembled and ad-hoc signed, never
# xcodebuild. Colleagues' machines have at best the Command Line Tools, and
# the build must work exactly there (PLATFORM-FACTS.md).

PREFIX       ?= $(HOME)/Applications
# THE production id, promoted for v1.0.0. macOS caches a notification
# permission verdict per bundle id FOREVER and a denial can never be undone
# (PLATFORM-FACTS.md § 1), so this line is a one-way door: never point it at a
# fresh id to "test something", and never let a test bundle ask for permission
# under it.
#
# Ids spent on the maintainer's Mac, and therefore unusable:
#   .dev   — denied on first install
#   .dev2  — the development id v1.0.0 was built under
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
BIN_DIR      ?= $(HOME)/.local/bin

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

.PHONY: build test app install uninstall clean

build:
	swift build -c release

test:
	swift test $(TEST_FLAGS)

# Assemble the bundle: both binaries inside Contents/MacOS — the bundle IS the
# notification identity, and the CLI posting from inside it is what lets a
# guard tick carry simmer's own icon.
# Quiet recipes: a non-technical colleague reads raw command echo as errors.
# The human-facing lines below are the output; `make V=1 …` shows the commands.
ifndef V
.SILENT:
endif

app: build
	rm -rf $(STAGED_APP)
	mkdir -p $(STAGED_APP)/Contents/MacOS $(STAGED_APP)/Contents/Resources
	sed -e 's/@BUNDLE_ID@/$(BUNDLE_ID)/g' -e 's/@VERSION@/$(VERSION)/g' \
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
	    launchd/guard.plist.template > $(AGENT_PLIST)
	# bootout returns before the job is gone — poll until it is
	launchctl bootout gui/$$(id -u)/$(GUARD_LABEL) 2>/dev/null || true
	i=0; while launchctl print gui/$$(id -u)/$(GUARD_LABEL) >/dev/null 2>&1; do \
	    i=$$((i+1)); [ $$i -gt 50 ] && break; sleep 0.1; done
	launchctl bootstrap gui/$$(id -u) $(AGENT_PLIST)
	echo "installed: $(APP)  (bundle id $(BUNDLE_ID))"
	echo "CLI:       $(BIN_DIR)/simmer  — make sure $(BIN_DIR) is on PATH"
	echo "guard:     $(GUARD_LABEL), every 30s and at login"
	# NOTES=0 (bootstrap.sh passes it) suppresses the what-remains epilogue —
	# bootstrap performs both steps itself right after this, and telling a
	# person to do what the next paragraph is about to do reads as a bug.
	[ "$(NOTES)" = "0" ] || { \
	    echo ""; \
	    echo "Two steps remain, both yours (they need a human):"; \
	    echo "  1. The sudo rule — bootstrap.sh installs it, or run it yourself:"; \
	    echo "       simmer doctor   # says whether it is in place, and prints the command"; \
	    echo "  2. open -a Simmer, then click Allow on the notification banner."; }

uninstall:
	-launchctl bootout gui/$$(id -u)/$(GUARD_LABEL) 2>/dev/null
	rm -f $(AGENT_PLIST)
	-[ -d $(APP) ] && $(LSREGISTER) -u $(APP)
	rm -rf $(APP)
	rm -f $(BIN_DIR)/simmer
	@echo "Removed the app, the CLI symlink and the guard."
	@echo "Left alone if present (needs root, and only if simmer wrote it):"
	@echo "  /etc/sudoers.d/simmer — remove with: sudo rm /etc/sudoers.d/simmer"

clean:
	swift package clean
	rm -rf $(STAGED_APP)
