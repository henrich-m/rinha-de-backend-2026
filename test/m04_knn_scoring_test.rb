# frozen_string_literal: true

require "minitest/autorun"
require "net/http"
require "json"

class KnnScoringTest < Minitest::Test
  BASE_URI = URI("http://localhost:9999")

  FRAUD_PAYLOAD = {
    id: "tx-3330991687",
    transaction: { amount: 9505.97, installments: 10, requested_at: "2026-03-14T05:15:12Z" },
    customer: { avg_amount: 81.28, tx_count_24h: 20, known_merchants: ["MERC-008", "MERC-007", "MERC-005"] },
    merchant: { id: "MERC-068", mcc: "7802", avg_amount: 54.86 },
    terminal: { is_online: false, card_present: true, km_from_home: 952.27 },
    last_transaction: nil
  }.freeze

  LEGIT_PAYLOAD = {
    id: "tx-1329056812",
    transaction: { amount: 41.12, installments: 2, requested_at: "2026-03-11T18:45:53Z" },
    customer: { avg_amount: 82.24, tx_count_24h: 3, known_merchants: ["MERC-003", "MERC-016"] },
    merchant: { id: "MERC-016", mcc: "5411", avg_amount: 60.25 },
    terminal: { is_online: false, card_present: true, km_from_home: 29.23 },
    last_transaction: nil
  }.freeze

  def test_fraud_transaction_is_denied
    body = post_fraud_score(FRAUD_PAYLOAD)
    assert_equal false, body["approved"], "fraud transaction must not be approved"
    assert_equal 1.0, body["fraud_score"], "all 5 neighbors must be fraud"
  end

  def test_legit_transaction_is_approved
    body = post_fraud_score(LEGIT_PAYLOAD)
    assert_equal true, body["approved"], "legit transaction must be approved"
    assert_equal 0.0, body["fraud_score"], "all 5 neighbors must be legit"
  end

  def test_fraud_score_is_between_zero_and_one
    body = post_fraud_score(LEGIT_PAYLOAD)
    assert_operator body["fraud_score"], :>=, 0.0
    assert_operator body["fraud_score"], :<=, 1.0
  end

  def test_approved_reflects_threshold
    body = post_fraud_score(FRAUD_PAYLOAD)
    expected_approved = body["fraud_score"] < 0.6
    assert_equal expected_approved, body["approved"], "approved must equal fraud_score < 0.6"
  end

  private

  def post_fraud_score(payload)
    uri = URI("#{BASE_URI}/fraud-score")
    req = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
    req.body = payload.to_json
    res = Net::HTTP.start(uri.host, uri.port) { |h| h.request(req) }
    JSON.parse(res.body)
  end
end
