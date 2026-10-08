TEST ?= test
COMPOSE ?= docker compose

.PHONY: build test demo shell clean

build:
	$(COMPOSE) build tests

test: build
	$(COMPOSE) run --rm tests pwsh -NoProfile -NonInteractive -File build/Invoke-Tests.ps1 -Path $(TEST)

demo: build
	$(COMPOSE) run --rm demo

shell: build
	$(COMPOSE) run --rm tests pwsh -NoProfile

clean:
	rm -rf out logs
	$(COMPOSE) down
