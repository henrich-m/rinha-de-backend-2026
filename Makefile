.PHONY: build up down logs-api logs-search test update-bundle-cache

RUBY_IMAGE := ruby:4
BUNDLE_VOLUME := bundle_cache

## Build all images
build:
	docker compose build

## Start the full stack in the background
up:
	docker compose up -d

## Stop and remove containers
down:
	docker compose down

## Tail API logs (Ctrl-C to stop)
logs-api:
	docker compose logs -f api-1 api-2

## Tail search logs (Ctrl-C to stop)
logs-search:
	docker compose logs -f search

## Run API unit tests (stack must be running)
test:
	docker compose exec api-1 bundle exec ruby -Itest test/server_unit_test.rb

## Install gems for api/ and search/ into the shared bundle_cache volume.
## Runs api first (no native deps), then search (needs build tools for faiss).
update-bundle-cache:
	docker run --rm -w /app \
		-v $(PWD)/api:/app \
		-v $(BUNDLE_VOLUME):/usr/local/bundle \
		$(RUBY_IMAGE) bundle install
	docker run --rm -w /app \
		-v $(PWD)/search:/app \
		-v $(BUNDLE_VOLUME):/usr/local/bundle \
		$(RUBY_IMAGE) bash -c "\
			apt-get update -qq && \
			apt-get install -y --no-install-recommends cmake g++ libblas-dev liblapack-dev && \
			bundle install"
