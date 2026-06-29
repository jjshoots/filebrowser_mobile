# filebrowser_mobile — local CI convenience.
#
# Flutter is not assumed on PATH: $(HOME)/flutter/bin is prepended when present.
# Targets:
#   make get      pub get
#   make analyze  static analysis
#   make test     unit/widget tests (no server; excludes integration)
#   make ci       get + analyze + test  (mirrors the PR `unit` gate)
#   make serve    boot the official quantum test server on :8080
#   make e2e      serve + run the integration-tagged tests against it
#   make clean    flutter clean + drop the test-server work dir

SHELL := /bin/sh

# Prefer ~/flutter/bin if flutter isn't already resolvable.
FLUTTER_BIN := $(HOME)/flutter/bin
FLUTTER := $(shell command -v flutter 2>/dev/null || echo $(FLUTTER_BIN)/flutter)

FB_TEST_URL ?= http://localhost:8080
FB_TEST_PORT ?= 8080

.PHONY: get analyze test ci serve e2e clean

get:
	$(FLUTTER) pub get

analyze: get
	$(FLUTTER) analyze

# Unit + widget tests only. The integration tag is skip-by-default and also
# excluded here, so this needs no server.
test: get
	$(FLUTTER) test --exclude-tags integration

ci: get analyze test

# Foreground server (Ctrl-C to stop). Idempotent setup happens inside the script.
serve:
	./tool/serve.sh run

# Boot the server in the background, wait for readiness, run the integration
# tests against it, then always stop the server.
e2e: get
	@mkdir -p .quantum-test; \
	./tool/serve.sh run > .quantum-test/serve.log 2>&1 & echo $$! > .quantum-test/serve.pid; \
	trap 'kill `cat .quantum-test/serve.pid` 2>/dev/null || true' EXIT INT TERM; \
	echo "waiting for $(FB_TEST_URL) ..."; \
	for i in $$(seq 1 60); do \
	  if curl -fsS -o /dev/null "$(FB_TEST_URL)/health" 2>/dev/null \
	     || curl -fsS -o /dev/null "$(FB_TEST_URL)/" 2>/dev/null; then \
	    echo "server ready"; break; \
	  fi; \
	  sleep 1; \
	  if [ $$i -eq 60 ]; then echo "server did not come up"; cat .quantum-test/serve.log; exit 1; fi; \
	done; \
	FB_TEST_URL=$(FB_TEST_URL) $(FLUTTER) test --tags integration --run-skipped

clean:
	$(FLUTTER) clean
	rm -rf .quantum-test
