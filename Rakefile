# frozen_string_literal: true

require "rake/testtask"

INFRA_TESTS = %w[test/m05_baked_image_test.rb test/m06_containerization_test.rb].freeze

# Default suite: unit + integration tests that run against the dev stack.
# Excludes infra tests that require separately built/running images.
Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.test_files = FileList["test/**/*_test.rb"].exclude(*INFRA_TESTS)
  t.warning = false
end

# Run only after: docker build -f Dockerfile.db -t rinha-db:local .
# and:            docker run -d --name rinha-db-test -p 5432:5432 rinha-db:local
Rake::TestTask.new(:test_baked) do |t|
  t.libs << "test"
  t.test_files = ["test/m05_baked_image_test.rb"]
  t.warning = false
end

# Run only after: docker compose up -d (with images built and pushed)
Rake::TestTask.new(:test_stack) do |t|
  t.libs << "test"
  t.test_files = ["test/m06_containerization_test.rb"]
  t.warning = false
end

task default: :test
