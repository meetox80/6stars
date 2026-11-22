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

.PHONY: all engine rpftool app run clean buildinfo

BUILD_INFO = Sources/SixStars/BuildInfo.swift

all: buildinfo | $(CACHE_DIRS)
	$(SWIFT_BUILD)

engine: buildinfo | $(CACHE_DIRS)
	$(SWIFT_BUILD) --product 6stars

buildinfo:
	@printf 'enum BuildInfo {\n    static let date = "%s"\n}\n' "$$(date -u '+%Y-%m-%d %H:%M UTC')" > $(BUILD_INFO).tmp
	@cmp -s $(BUILD_INFO).tmp $(BUILD_INFO) && rm $(BUILD_INFO).tmp || mv $(BUILD_INFO).tmp $(BUILD_INFO)

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
	rm -rf .build $(BUILD_INFO)

$(CACHE_DIRS):
	mkdir -p $@
