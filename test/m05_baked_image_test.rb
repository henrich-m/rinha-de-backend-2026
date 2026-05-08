# frozen_string_literal: true

require "minitest/autorun"
require "pg"

# Before running this test:
#   docker build -f Dockerfile.db -t rinha-db:local .
#   docker run -d --name rinha-db-test -p 5432:5432 rinha-db:local
#   # wait ~5s for postgres to start, then:
#   DATABASE_URL=postgres://postgres@localhost:5432/rinha bundle exec ruby -Itest test/m05_baked_image_test.rb
#   docker rm -f rinha-db-test

class BakedImageTest < Minitest::Test
  def conn
    url = ENV.fetch("DATABASE_URL", "postgres://postgres:postgres@localhost:5432/rinha")
    @conn ||= PG.connect(url)
  end

  def test_row_count
    result = conn.exec("SELECT COUNT(*) FROM refs")
    assert_equal "3000000", result[0]["count"], "pre-baked image must contain 3M rows"
  end

  def test_hnsw_index_exists
    result = conn.exec(<<~SQL)
      SELECT indexname FROM pg_indexes
      WHERE tablename = 'refs' AND indexdef ILIKE '%hnsw%'
    SQL
    refute_empty result.to_a, "HNSW index must exist on refs.embedding"
  end

  def test_postgres_conf_max_connections
    result = conn.exec("SHOW max_connections")
    assert_operator result[0]["max_connections"].to_i, :<=, 20
  end
end
