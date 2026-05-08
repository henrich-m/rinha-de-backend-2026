# frozen_string_literal: true

require "minitest/autorun"
require "rack/test"
require "json"
require_relative "../src/db"

# Stub DB before requiring server so the constant exists at request time.
StubConn = Struct.new(:result) { def exec_params(*) = result }
DB = Db.new(conn: StubConn.new([{"?column?" => "1"}]))

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
