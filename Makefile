PREFIX ?= /usr/local
BINDIR  = $(PREFIX)/bin
BIN     = .build/release/gpuscale

.PHONY: all build release debug install realesrgan uninstall clean test help

all: release

## build / release: compile the optimized binary
build release:
	swift build -c release

## debug: compile an unoptimized binary (faster builds)
debug:
	swift build

## install: build and copy gpuscale + wrappers into $(BINDIR)
install: release
	install -d "$(BINDIR)"
	install -m 0755 "$(BIN)" "$(BINDIR)/gpuscale"
	install -m 0755 bin/gpuscale-full "$(BINDIR)/gpuscale-full"
	install -m 0755 bin/realesr-video "$(BINDIR)/realesr-video"
	install -m 0755 bin/vidscale      "$(BINDIR)/vidscale"
	@echo "installed to $(BINDIR)"

## realesrgan: download the Real-ESRGAN GPU engine (for the AI method)
realesrgan:
	./scripts/install-realesrgan.sh

## uninstall: remove installed binaries
uninstall:
	rm -f "$(BINDIR)/gpuscale" "$(BINDIR)/gpuscale-full" \
	      "$(BINDIR)/realesr-video" "$(BINDIR)/vidscale"

## clean: remove build artifacts
clean:
	swift package clean
	rm -rf .build

## test: run the smoke test (needs ffmpeg)
test: release
	./examples/examples.sh --self-test

## help: list targets
help:
	@grep -E '^##' Makefile | sed 's/## /  /'
