# Photons — acceptance harness
#
# One command must prove the project is healthy:  make verify
#
# RAW is not vendored; point it at your own sample:
#   make verify RAW=~/Pictures/foo.dng
# or export PHOTONS_TEST_RAW once.

RAW ?= $(HOME)/Desktop/test/L1030433.dng
GOLDEN_DIR ?= Tests/Golden
EDIT_DIR ?= Tests/Fixtures
CONFIG ?= release
BIN := .build/$(CONFIG)/photonsctl
CACHE_DIR ?= $(HOME)/Library/Caches/Photons/linear
VIEWPORT ?= 2560x1600

.PHONY: all build test l1 l2 l3 catalog catalog-perf bench verify record clean info cache render

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

## L3 — the M1 editing graph: determinism, edit sensitivity, stage cache, golden pixels
l3: build
	@test -f "$(RAW)" || { echo "L3 SKIP: no fixture at $(RAW)"; exit 1; }
	@$(BIN) render "$(RAW)" --edit $(EDIT_DIR)/edit-neutral.json --out /tmp/photons-l3-a.jpg --scale 0.25 > /tmp/photons-l3-a.txt 2>&1 || { cat /tmp/photons-l3-a.txt; exit 1; }
	@$(BIN) render "$(RAW)" --edit $(EDIT_DIR)/edit-neutral.json --out /tmp/photons-l3-b.jpg --scale 0.25 > /tmp/photons-l3-b.txt 2>&1 || { cat /tmp/photons-l3-b.txt; exit 1; }
	@A=$$(shasum -a 256 /tmp/photons-l3-a.jpg | cut -d' ' -f1); B=$$(shasum -a 256 /tmp/photons-l3-b.jpg | cut -d' ' -f1); \
	 if [ "$$A" = "$$B" ]; then echo "L3 determinism  PASS  $${A}"; else echo "L3 determinism  FAIL  $$A != $$B"; exit 1; fi
	@$(BIN) render "$(RAW)" --edit $(EDIT_DIR)/edit-push.json --out /tmp/photons-l3-c.jpg --scale 0.25 > /tmp/photons-l3-c.txt 2>&1 || { cat /tmp/photons-l3-c.txt; exit 1; }
	@C=$$(shasum -a 256 /tmp/photons-l3-c.jpg | cut -d' ' -f1); A=$$(shasum -a 256 /tmp/photons-l3-a.jpg | cut -d' ' -f1); \
	 if [ "$$C" != "$$A" ]; then echo "L3 edit-sensitivity PASS"; else echo "L3 edit-sensitivity FAIL: push == neutral"; exit 1; fi
	@$(BIN) render "$(RAW)" --edit $(EDIT_DIR)/edit-neutral.json --edit $(EDIT_DIR)/edit-color.json \
		--out /tmp/photons-l3-t.jpg --scale 0.25 --trace-stages > /tmp/photons-l3-t.txt 2>&1 || { cat /tmp/photons-l3-t.txt; exit 1; }
	@awk '/^edit       edit-color/{f=1} f&&/^stages/{print;exit}' /tmp/photons-l3-t.txt | grep -qv "s0-geometry" \
		&& echo "L3 stage-cache   PASS  (S3-only change skipped S0/S1/S2)" \
		|| { echo "L3 stage-cache   FAIL: S0 re-ran on an S3-only change"; cat /tmp/photons-l3-t.txt; exit 1; }
	@if [ -z "$$(ls -A $(GOLDEN_DIR)/render-*.json 2>/dev/null)" ]; then \
		echo "L3 render golden (recording)"; \
		$(BIN) render "$(RAW)" --edit $(EDIT_DIR)/edit-neutral.json --out /tmp/photons-l3-g.jpg --scale 0.25 --golden record > /dev/null; \
		$(BIN) render "$(RAW)" --edit $(EDIT_DIR)/edit-push.json --out /tmp/photons-l3-g2.jpg --scale 0.25 --golden record > /dev/null; \
	fi
	@$(BIN) render "$(RAW)" --edit $(EDIT_DIR)/edit-neutral.json --out /tmp/photons-l3-g.jpg --scale 0.25 --golden check | grep "golden"
	@$(BIN) render "$(RAW)" --edit $(EDIT_DIR)/edit-push.json --out /tmp/photons-l3-g2.jpg --scale 0.25 --golden check | grep "golden"

## M2 — catalog + import: dedupe, resume after kill, move, offline, migrations, metadata
catalog: build
	@BIN=$(BIN) RAW="$(RAW)" Tests/catalog-acceptance.sh

## same, plus the 10k-row query timing (~90 s; not part of `make verify`)
catalog-perf: build
	@BIN=$(BIN) RAW="$(RAW)" Tests/catalog-acceptance.sh --perf

## frame budget: full S0→S4 at viewport size must fit 60 fps
bench: build
	@test -f "$(RAW)" || { echo "bench SKIP: no fixture at $(RAW)"; exit 1; }
	@$(BIN) bench "$(RAW)" --viewport $(VIEWPORT) --iterations 60 --edit $(EDIT_DIR)/edit-push.json

render: build
	@$(BIN) render "$(RAW)" --edit $(EDIT_DIR)/edit-push.json --out /tmp/photons-render.jpg --scale 0.25 --trace-stages

verify: build test l1 l2 l3 catalog bench
	@echo "------------------------------------------------"
	@echo "ALL GREEN: build + unit tests + L1/L2 decode + L3 graph + M2 catalog + bench"

record: build
	$(BIN) golden record "$(RAW)" --dir $(GOLDEN_DIR)

info: build
	$(BIN) info "$(RAW)"

cache: build
	$(BIN) cache --dir $(CACHE_DIR)

clean:
	swift package clean
	rm -rf .build
