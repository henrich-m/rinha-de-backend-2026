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
	docker compose cp test/m02_vectorization_test.rb api-1:/app/test/m02_vectorization_test.rb
	docker compose exec api-1 bundle exec ruby test/m02_vectorization_test.rb
	docker run --rm --network host \
		-v $(PWD):/repo \
		$(RUBY_IMAGE) ruby -e "Dir['/repo/test/m0[^2]*.rb'].sort.each { |f| require f }"

