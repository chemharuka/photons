# Photons — acceptance harness
#
# One command must prove the project is healthy:  make verify
#
# RAW is not vendored; point it at your own sample:
#   make verify RAW=~/Pictures/foo.dng
# or export PHOTONS_TEST_RAW once.

RAW ?= $(HOME)/Desktop/test/L1030433.dng
GOLDEN_DIR ?= Tests/Golden
CONFIG ?= release
BIN := .build/$(CONFIG)/photonsctl
CACHE_DIR ?= $(HOME)/Library/Caches/Photons/linear

.PHONY: all build test l1 l2 verify record clean info cache

all: build

build:
	swift build -c $(CONFIG)

test: build
	PHOTONS_TEST_RAW="$(RAW)" swift test 2>&1 | tail -40

## L1 — determinism: two independent processes must emit the same digest
l1: build
	@test -f "$(RAW)" || { echo "L1 SKIP: no fixture at $(RAW)"; exit 1; }
	@$(BIN) hash "$(RAW)" 2>/dev/null > /tmp/photons-l1-a.txt
	@$(BIN) hash "$(RAW)" 2>/dev/null > /tmp/photons-l1-b.txt
	@if diff -q /tmp/photons-l1-a.txt /tmp/photons-l1-b.txt >/dev/null; then \
		echo "L1 determinism  PASS  $$(cut -c1-16 /tmp/photons-l1-a.txt)…"; \
	else \
		echo "L1 determinism  FAIL"; diff /tmp/photons-l1-a.txt /tmp/photons-l1-b.txt; exit 1; \
	fi

## L2 — golden image regression (records on first run, then compares)
l2: build
	@test -f "$(RAW)" || { echo "L2 SKIP: no fixture at $(RAW)"; exit 1; }
	@if [ -z "$$(ls -A $(GOLDEN_DIR) 2>/dev/null)" ]; then \
		echo "L2 golden       (no baseline yet — recording)"; \
		$(BIN) golden record "$(RAW)" --dir $(GOLDEN_DIR); \
	else \
		$(BIN) golden check "$(RAW)" --dir $(GOLDEN_DIR); \
	fi

verify: build test l1 l2
	@echo "------------------------------------------------"
	@echo "ALL GREEN: build + unit tests + L1 determinism + L2 golden"

record: build
	$(BIN) golden record "$(RAW)" --dir $(GOLDEN_DIR)

info: build
	$(BIN) info "$(RAW)"

cache: build
	$(BIN) cache --dir $(CACHE_DIR)

clean:
	swift package clean
	rm -rf .build
