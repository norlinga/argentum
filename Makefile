# Everything runs in Docker: the host needs only Docker (with Compose v2) and make.
# `make` on its own lists the targets.

COMPOSE := docker compose
DEV     := $(COMPOSE) --profile dev
IMAGE   := argentum

# Forward TEST/TESTOPTS to the container only when given: an empty TEST makes
# Rake select no files and "pass" without running anything.
TEST_ENV := $(if $(TEST),-e TEST='$(TEST)') $(if $(TESTOPTS),-e TESTOPTS='$(TESTOPTS)')

.DEFAULT_GOAL := help
.PHONY: help test test-local dev shell build smoke check up down logs ps clean

help: ## List targets
	@awk 'BEGIN { FS = ":.*## " } \
	  /^##@/ { printf "\n%s\n", substr($$0, 5) } \
	  /^[a-z-]+:.*## / { printf "  make %-11s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@echo

##@ Development (working copy, bind-mounted — no rebuild needed after edits)

test: ## Run the test suite. Narrow it: TEST=test/app_test.rb TESTOPTS=--name=/favorite/
	$(DEV) run --rm --build $(TEST_ENV) test

test-local: ## Run the tests on the host instead (needs Ruby, `bundle install`, ffmpeg)
	bundle exec rake test $(if $(TEST),TEST='$(TEST)') $(if $(TESTOPTS),TESTOPTS='$(TESTOPTS)')

dev: ## Serve the working copy on http://localhost:4568 (ARGENTUM_DEV_PORT; own data volume)
	$(DEV) up --build dev

shell: ## Open a bash shell in the dev image
	$(DEV) run --rm --build dev bash

##@ Production image

build: ## Build the production image
	$(COMPOSE) build argentum

smoke: build ## Boot the production image on a sample clip; check ingest, HLS and serving
	bin/smoke $(IMAGE)

check: test smoke ## Everything worth running before a push or release

up: ## Start the app in the background on http://localhost:4567 (ARGENTUM_PORT; reads .env)
	$(COMPOSE) up -d --build argentum

down: ## Stop the app (the library volume is kept)
	$(COMPOSE) stop argentum
	$(COMPOSE) rm -f argentum

logs: ## Follow the app's logs
	$(COMPOSE) logs -f argentum

ps: ## Show running containers
	$(DEV) ps

clean: ## Remove dev/test containers, images and the dev data volume (never the production library)
	$(DEV) rm -fsv dev test
	-docker image rm argentum:dev argentum:test
	-docker volume rm argentum-dev-data
