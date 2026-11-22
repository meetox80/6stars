CONFIG ?= release
CACHE ?= $(HOME)/testing/.cache
APP ?= $(HOME)/testing/6stars.app
BIN = .build/$(CONFIG)

export TMPDIR := $(CACHE)/tmp/
export CLANG_MODULE_CACHE_PATH := $(CACHE)/clang
export SWIFTPM_MODULECACHE_OVERRIDE := $(CACHE)/clang

CACHE_DIRS = $(CACHE)/tmp $(CACHE)/clang $(CACHE)/swiftpm $(CACHE)/swiftpm-config $(CACHE)/swiftpm-security
SWIFT_BUILD = swift build -c $(CONFIG) \
	--scratch-path $(CURDIR)/.build \
	--cache-path $(CACHE)/swiftpm \
	--config-path $(CACHE)/swiftpm-config \
	--security-path $(CACHE)/swiftpm-security \
	--manifest-cache local

.PHONY: all engine rpftool app run clean

all: | $(CACHE_DIRS)
	$(SWIFT_BUILD)

engine: | $(CACHE_DIRS)
	$(SWIFT_BUILD) --product 6stars

rpftool: | $(CACHE_DIRS)
	$(SWIFT_BUILD) --product rpftool

app: engine
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS"
	cp $(BIN)/6stars "$(APP)/Contents/MacOS/6stars"
	cp Support/Info.plist "$(APP)/Contents/Info.plist"
	codesign --force --sign - "$(APP)"

run: engine
	$(BIN)/6stars $(ARGS)

clean:
	rm -rf .build

$(CACHE_DIRS):
	mkdir -p $@
