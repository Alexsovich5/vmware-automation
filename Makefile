TEST ?= test
COMPOSE ?= docker compose

.PHONY: build test shell clean

build:
	$(COMPOSE) build tests

test: build
	$(COMPOSE) run --rm tests pwsh -NoProfile -NonInteractive -File build/Invoke-Tests.ps1 -Path $(TEST)

shell: build
	$(COMPOSE) run --rm tests pwsh -NoProfile

clean:
	rm -rf out logs
	$(COMPOSE) down
