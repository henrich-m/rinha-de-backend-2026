.PHONY: build up down logs-api test update-bundle-cache

RUBY_IMAGE := ruby:4
BUNDLE_VOLUME := bundle_cache

## Train KNN model and build all images
build:
	docker compose --profile build run --rm trainer
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

## Run unit tests (inside container) and integration tests (against localhost:9999)
test:
	docker compose exec api-1 bundle exec ruby -Itest test/server_unit_test.rb
	docker run --rm --network host \
		-v $(PWD)/test:/test \
		$(RUBY_IMAGE) ruby -e "Dir['/test/m*.rb'].sort.each { |f| require f }"

## Install gems into the shared bundle_cache volume (needs build tools for faiss).
update-bundle-cache:
	docker run --rm -w /app \
		-v $(PWD)/api:/app \
		-v $(BUNDLE_VOLUME):/usr/local/bundle \
		$(RUBY_IMAGE) bash -c "\
			apt-get update -qq && \
			apt-get install -y --no-install-recommends cmake g++ libblas-dev liblapack-dev && \
			bundle install"
