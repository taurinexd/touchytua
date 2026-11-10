# touchytua build entry points.
#
# TESTFLAGS work around a Command Line Tools quirk on macOS 26: `swift test`
# does not add the Developer Frameworks / lib paths where Testing.framework
# lives. With full Xcode installed they are harmless no-ops.

DEVFW := /Library/Developer/CommandLineTools/Library/Developer/Frameworks
DEVLIB := /Library/Developer/CommandLineTools/Library/Developer/usr/lib

ifneq (,$(wildcard $(DEVFW)))
TESTFLAGS := -Xswiftc -F$(DEVFW) -Xlinker -F$(DEVFW) \
	-Xlinker -rpath -Xlinker $(DEVFW) \
	-Xlinker -rpath -Xlinker $(DEVLIB)
endif

.PHONY: build test

build:
	cd mac && swift build

test:
	cd mac && swift test $(TESTFLAGS)

.PHONY: hook-smoke
hook-smoke: build
	tests/hook-smoke.sh mac/.build/debug/touchytua-hook

.PHONY: statusline-smoke
statusline-smoke: build
	tests/statusline-smoke.sh mac/.build/debug/touchytua-statusline

.PHONY: daemon-smoke
daemon-smoke: build
	tests/daemon-smoke.sh mac/.build/debug/touchytuad mac/.build/debug/touchytua-hook
