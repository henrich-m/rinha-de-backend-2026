# frozen_string_literal: true

require "minitest/autorun"
require "rack/test"
require "json"
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

  def test_ready_returns_200
    get "/ready"
    assert_equal 200, last_response.status
  end

  def test_fraud_score_returns_200
    post "/fraud-score", STUB_PAYLOAD.to_json, "CONTENT_TYPE" => "application/json"
    assert_equal 200, last_response.status
  end

  def test_fraud_score_response_has_approved_key
    post "/fraud-score", STUB_PAYLOAD.to_json, "CONTENT_TYPE" => "application/json"
    body = JSON.parse(last_response.body)
    assert body.key?("approved"), "response must include 'approved'"
  end

  def test_fraud_score_response_has_fraud_score_key
    post "/fraud-score", STUB_PAYLOAD.to_json, "CONTENT_TYPE" => "application/json"
    body = JSON.parse(last_response.body)
    assert body.key?("fraud_score"), "response must include 'fraud_score'"
  end

  def test_fraud_score_content_type_is_json
    post "/fraud-score", STUB_PAYLOAD.to_json, "CONTENT_TYPE" => "application/json"
    assert_match "application/json", last_response.content_type
  end
end
