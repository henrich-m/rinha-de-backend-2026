# frozen_string_literal: true

require "minitest/autorun"
require "net/http"
require "pg"

class PostgresSetupTest < Minitest::Test
  def conn
    @conn ||= PG.connect(ENV.fetch("DATABASE_URL"))
  end

  def test_extension_is_enabled
    result = conn.exec("SELECT extname FROM pg_extension WHERE extname = 'vector'")
    refute_empty result.to_a, "pgvector extension must be installed"
  end

  def test_refs_table_exists
    result = conn.exec("SELECT to_regclass('public.refs')")
    refute_nil result[0]["to_regclass"], "refs table must exist"
  end

  def test_row_count
    result = conn.exec("SELECT COUNT(*) FROM refs")
    assert_equal "3000000", result[0]["count"], "refs must contain exactly 3M rows"
  end

  def test_vector_dimensionality
    result = conn.exec("SELECT vector_dims(embedding) AS dims FROM refs LIMIT 1")
    assert_equal "14", result[0]["dims"], "each embedding must have 14 dimensions"
  end

  def test_ready_endpoint_returns_200_when_db_is_up
    res = Net::HTTP.get_response(URI("http://localhost:9999/ready"))
    assert_equal "200", res.code, "/ready must return 200 when database is reachable"
  end
end
