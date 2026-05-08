# frozen_string_literal: true

require "minitest/autorun"
require "net/http"
require "json"
require "yaml"

# Requires the full stack running:
#   docker compose up -d  (after building and pushing images)

class ContainerizationTest < Minitest::Test
  BASE_URI = URI("http://localhost:9999")

  STUB_PAYLOAD = {
    id: "tx-smoke",
    transaction: { amount: 100, installments: 1, requested_at: "2026-03-11T10:00:00Z" },
    customer: { avg_amount: 200, tx_count_24h: 1, known_merchants: [] },
    merchant: { id: "MERC-001", mcc: "5411", avg_amount: 80 },
    terminal: { is_online: false, card_present: true, km_from_home: 5 },
    last_transaction: nil
  }.freeze

  def test_ready_via_load_balancer
    res = Net::HTTP.get_response(URI("#{BASE_URI}/ready"))
    assert_equal "200", res.code, "/ready must return 200 through nginx"
  end

  def test_fraud_score_via_load_balancer
    body = post_fraud_score(STUB_PAYLOAD)
    assert body.key?("approved"), "response must include 'approved'"
    assert body.key?("fraud_score"), "response must include 'fraud_score'"
  end

  def test_total_cpu_within_budget
    assert_operator total_cpu, :<=, 1.0, "total declared CPU must not exceed 1.0"
  end

  def test_total_memory_within_budget
    assert_operator total_memory_mb, :<=, 350.0, "total declared memory must not exceed 350 MB"
  end

  private

  def post_fraud_score(payload)
    uri = URI("#{BASE_URI}/fraud-score")
    req = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
    req.body = payload.to_json
    res = Net::HTTP.start(uri.host, uri.port) { |h| h.request(req) }
    JSON.parse(res.body)
  end

  def compose_config
    @compose_config ||= YAML.safe_load(`docker compose config`)
  end

  def total_cpu
    compose_config["services"].sum do |_, svc|
      svc.dig("deploy", "resources", "limits", "cpus").to_f
    end
  end

  def total_memory_mb
    compose_config["services"].sum do |_, svc|
      mem = svc.dig("deploy", "resources", "limits", "memory").to_s
      mem.end_with?("MB") ? mem.to_f : mem.to_f / 1_048_576.0
    end
  end
end
