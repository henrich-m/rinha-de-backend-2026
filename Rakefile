# frozen_string_literal: true

require "rake/testtask"

# Default suite: unit + integration tests that run against the dev stack.
# Excludes m05 which requires a separately built rinha-db:local image.
Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.test_files = FileList["test/**/*_test.rb"].exclude("test/m05_baked_image_test.rb")
  t.warning = false
end

# Run only after: docker build -f Dockerfile.db -t rinha-db:local .
# and:            docker run -d --name rinha-db-test -p 5432:5432 rinha-db:local
Rake::TestTask.new(:test_baked) do |t|
  t.libs << "test"
  t.test_files = ["test/m05_baked_image_test.rb"]
  t.warning = false
end

task default: :test
