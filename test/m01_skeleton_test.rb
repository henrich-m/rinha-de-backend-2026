# frozen_string_literal: true

require "minitest/autorun"
require "net/http"
require "json"

class SkeletonTest < Minitest::Test
  BASE_URI = URI("http://localhost:9999")

  STUB_PAYLOAD = {
    id: "tx-1",
    transaction: { amount: 100, installments: 1, requested_at: "2026-03-11T18:45:53Z" },
    customer: { avg_amount: 200, tx_count_24h: 1, known_merchants: [] },
    merchant: { id: "MERC-001", mcc: "5411", avg_amount: 80 },
    terminal: { is_online: false, card_present: true, km_from_home: 5 },
    last_transaction: nil
  }.freeze

  def test_ready_returns_200
    res = Net::HTTP.get_response(URI("#{BASE_URI}/ready"))
    assert_equal "200", res.code
  end

  def test_fraud_score_returns_200
    res = post_fraud_score(STUB_PAYLOAD)
    assert_equal "200", res.code
  end

  def test_fraud_score_returns_approved_key
    body = JSON.parse(post_fraud_score(STUB_PAYLOAD).body)
    assert body.key?("approved"), "response must include 'approved'"
  end

  def test_fraud_score_returns_fraud_score_key
    body = JSON.parse(post_fraud_score(STUB_PAYLOAD).body)
    assert body.key?("fraud_score"), "response must include 'fraud_score'"
  end

  private

  def post_fraud_score(payload)
    uri = URI("#{BASE_URI}/fraud-score")
    req = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
    req.body = payload.to_json
    Net::HTTP.start(uri.host, uri.port) { |h| h.request(req) }
  end
end
