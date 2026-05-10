# frozen_string_literal: true

require "minitest/autorun"
require "rack/test"
require "json"
require_relative "../src/vectorizer"

# Stub VECTORIZER before requiring server so the constant exists at request time.
StubVectorizer = Struct.new(:vector) { def vectorize(_payload) = vector || [0.0] * 14 }
VECTORIZER = StubVectorizer.new

SEARCH_URL = "http://search:9294"

require_relative "../src/server"

# Mock response object returned by Search stubs
MockResponse = Struct.new(:status, :body) do
  def read = body
end

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

  def setup
    # Default stubs: search is ready, all-legit neighbors
    Search.define_singleton_method(:ready?) { MockResponse.new(200, "Ready") }
    Search.define_singleton_method(:knn) { |_v| { "results" => [0, 0, 0, 0, 0] } }
  end

  def teardown
    # Reset to default stubs after each test
    Search.define_singleton_method(:ready?) { MockResponse.new(200, "Ready") }
    Search.define_singleton_method(:knn) { |_v| { "results" => [0, 0, 0, 0, 0] } }
  end

  def test_ready_returns_200_when_db_is_up
    get "/ready"
    assert_equal 200, last_response.status
  end

  def test_ready_returns_503_when_db_is_down
    Search.define_singleton_method(:ready?) { raise "search unavailable" }
    get "/ready"
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
    Search.define_singleton_method(:knn) { |_v| { "results" => [1, 1, 1, 1, 1] } }
    post "/fraud-score", STUB_PAYLOAD.to_json, "CONTENT_TYPE" => "application/json"
    body = JSON.parse(last_response.body)
    assert_equal 1.0,   body["fraud_score"]
    assert_equal false, body["approved"]
  end

  def test_all_legit_neighbors_returns_score_0_and_approved
    Search.define_singleton_method(:knn) { |_v| { "results" => [0, 0, 0, 0, 0] } }
    post "/fraud-score", STUB_PAYLOAD.to_json, "CONTENT_TYPE" => "application/json"
    body = JSON.parse(last_response.body)
    assert_equal 0.0,  body["fraud_score"]
    assert_equal true, body["approved"]
  end

  def test_two_fraud_neighbors_approved
    Search.define_singleton_method(:knn) { |_v| { "results" => [1, 1, 0, 0, 0] } }
    post "/fraud-score", STUB_PAYLOAD.to_json, "CONTENT_TYPE" => "application/json"
    body = JSON.parse(last_response.body)
    assert_equal 0.4,  body["fraud_score"]
    assert_equal true, body["approved"]
  end

  def test_three_fraud_neighbors_denied
    Search.define_singleton_method(:knn) { |_v| { "results" => [1, 1, 1, 0, 0] } }
    post "/fraud-score", STUB_PAYLOAD.to_json, "CONTENT_TYPE" => "application/json"
    body = JSON.parse(last_response.body)
    assert_equal 0.6,   body["fraud_score"]
    assert_equal false, body["approved"]
  end

  def test_db_exception_returns_approved_with_zero_score
    Search.define_singleton_method(:knn) { |_v| raise RuntimeError, "connection error" }
    post "/fraud-score", STUB_PAYLOAD.to_json, "CONTENT_TYPE" => "application/json"
    body = JSON.parse(last_response.body)
    assert_equal 200,  last_response.status
    assert_equal 0.0,  body["fraud_score"]
    assert_equal true, body["approved"]
  end
end
