# frozen_string_literal: true

require "minitest/autorun"
require_relative "../src/db"

class DbUnitTest < Minitest::Test
  StubConn = Struct.new(:result) { def exec_params(*) = result }

  def stub_db(result)
    Db.new(conn: StubConn.new(result))
  end

  def test_knn_returns_conn_result
    rows = [{"is_fraud" => "t"}, {"is_fraud" => "f"}]
    assert_equal rows, stub_db(rows).knn([0.1] * 14)
  end

  def test_knn_formats_vector_as_bracket_notation
    sent_params = nil
    conn = Object.new
    conn.define_singleton_method(:exec_params) { |_sql, params| sent_params = params; [] }
    Db.new(conn: conn).knn([0.1, 0.2, 0.3] + [0.0] * 11)
    assert_equal "[0.1,0.2,0.3,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0]", sent_params[0]
  end

  def test_knn_default_k_is_5
    sent_params = nil
    conn = Object.new
    conn.define_singleton_method(:exec_params) { |_sql, params| sent_params = params; [] }
    Db.new(conn: conn).knn([0.0] * 14)
    assert_equal 5, sent_params[1]
  end

  def test_ready_returns_true_when_query_succeeds
    assert stub_db([{"?column?" => "1"}]).ready?
  end

  def test_ready_returns_false_when_query_raises
    conn = Object.new
    conn.define_singleton_method(:exec_params) { raise "connection failed" }
    refute Db.new(conn: conn).ready?
  end
end
