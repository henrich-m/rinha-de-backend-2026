# frozen_string_literal: true

require "minitest/autorun"
require "rack/test"
require "json"
require_relative "../src/db"
require_relative "../src/vectorizer"

# Stub DB and VECTORIZER before requiring server so constants exist at request time.
StubConn = Struct.new(:result) { def exec_params(*) = result }
DB = Db.new(conn: StubConn.new(Array.new(5) { {"is_fraud" => "f"} }))

StubVectorizer = Struct.new(:vector) { def vectorize(_payload) = vector || [0.0] * 14 }
VECTORIZER = StubVectorizer.new

require_relative "../src/server"

class ServerUnitTest < Minitest::Test
  include Rack::Test::Methods

  def app = App

  STUB_PAYLOAD = {
    "id" => "tx-1",
    "transaction" => { "amount" => 100, "installments" => 1, "requested_at" => "2026-03-11T18:45:53Z" },
    "customer" => { "avg_amount" => 200, "tx_count_24h" => 1, "known_merchants" => [] },
    "merchant" => { "id" => "MERC-001", "mcc" => "5411", "avg_amount" => 80 },
    "terminal" => { "is_online" => false, "card_present" => true, "km_from_home" => 5 },
    "last_transaction" => nil
  }.freeze

  def test_ready_returns_200_when_db_is_up
    get "/ready"
    assert_equal 200, last_response.status
  end

  def test_ready_returns_503_when_db_is_down
    failing_conn = Object.new.tap { |c| c.define_singleton_method(:exec_params) { raise "no db" } }
    failing_db = Db.new(conn: failing_conn)
    with_db(failing_db) { get "/ready" }
    assert_equal 503, last_response.status
  end

  def test_fraud_score_returns_200
    post "/fraud-score", STUB_PAYLOAD.to_json, "CONTENT_TYPE" => "application/json"
    assert_equal 200, last_response.status
  end

  def test_fraud_score_response_has_approved_key
    post "/fraud-score", STUB_PAYLOAD.to_json, "CONTENT_TYPE" => "application/json"
    assert JSON.parse(last_response.body).key?("approved"), "response must include 'approved'"
  end

  def test_fraud_score_response_has_fraud_score_key
    post "/fraud-score", STUB_PAYLOAD.to_json, "CONTENT_TYPE" => "application/json"
    assert JSON.parse(last_response.body).key?("fraud_score"), "response must include 'fraud_score'"
  end

  def test_fraud_score_content_type_is_json
    post "/fraud-score", STUB_PAYLOAD.to_json, "CONTENT_TYPE" => "application/json"
    assert_match "application/json", last_response.content_type
  end

  def test_all_fraud_neighbors_returns_score_1_and_denied
    all_fraud = Db.new(conn: StubConn.new(Array.new(5) { {"is_fraud" => "t"} }))
    with_db(all_fraud) do
      post "/fraud-score", STUB_PAYLOAD.to_json, "CONTENT_TYPE" => "application/json"
    end
    body = JSON.parse(last_response.body)
    assert_equal 1.0,   body["fraud_score"]
    assert_equal false, body["approved"]
  end

  def test_all_legit_neighbors_returns_score_0_and_approved
    all_legit = Db.new(conn: StubConn.new(Array.new(5) { {"is_fraud" => "f"} }))
    with_db(all_legit) do
      post "/fraud-score", STUB_PAYLOAD.to_json, "CONTENT_TYPE" => "application/json"
    end
    body = JSON.parse(last_response.body)
    assert_equal 0.0,  body["fraud_score"]
    assert_equal true, body["approved"]
  end

  def test_two_fraud_neighbors_approved
    two_fraud = Db.new(conn: StubConn.new(
      [{"is_fraud" => "t"}, {"is_fraud" => "t"}] + Array.new(3) { {"is_fraud" => "f"} }
    ))
    with_db(two_fraud) do
      post "/fraud-score", STUB_PAYLOAD.to_json, "CONTENT_TYPE" => "application/json"
    end
    body = JSON.parse(last_response.body)
    assert_equal 0.4,  body["fraud_score"]
    assert_equal true, body["approved"]
  end

  def test_three_fraud_neighbors_denied
    three_fraud = Db.new(conn: StubConn.new(
      Array.new(3) { {"is_fraud" => "t"} } + [{"is_fraud" => "f"}, {"is_fraud" => "f"}]
    ))
    with_db(three_fraud) do
      post "/fraud-score", STUB_PAYLOAD.to_json, "CONTENT_TYPE" => "application/json"
    end
    body = JSON.parse(last_response.body)
    assert_equal 0.6,   body["fraud_score"]
    assert_equal false, body["approved"]
  end

  def test_db_exception_returns_approved_with_zero_score
    raising_conn = Object.new.tap do |c|
      c.define_singleton_method(:exec_params) { raise PG::Error, "connection error" }
    end
    raising_db = Db.new(conn: raising_conn)
    with_db(raising_db) do
      post "/fraud-score", STUB_PAYLOAD.to_json, "CONTENT_TYPE" => "application/json"
    end
    body = JSON.parse(last_response.body)
    assert_equal 200,  last_response.status
    assert_equal 0.0,  body["fraud_score"]
    assert_equal true, body["approved"]
  end

  private

  def with_db(db)
    old = Object.const_get(:DB)
    prev_verbose = $VERBOSE
    $VERBOSE = nil
    Object.const_set(:DB, db)
    $VERBOSE = prev_verbose
    yield
  ensure
    $VERBOSE = nil
    Object.const_set(:DB, old)
    $VERBOSE = prev_verbose
  end
end
