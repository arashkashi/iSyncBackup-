PREFIX ?= /usr/local
BIN := $(shell swift build -c release --show-bin-path 2>/dev/null)/isync

.PHONY: build test smoke install uninstall clean

build:            ## Release build → .build/release/isync
	swift build -c release

test:             ## Unit tests (planner logic)
	swift test

smoke: build      ## End-to-end filesystem tests
	./scripts/smoke-test.sh

install: build    ## Copy the binary to $(PREFIX)/bin (may need sudo)
	install -d "$(PREFIX)/bin"
	install -m 755 "$(BIN)" "$(PREFIX)/bin/isync"
	@echo "installed $(PREFIX)/bin/isync"

uninstall:
	rm -f "$(PREFIX)/bin/isync"

clean:
	rm -rf .build
