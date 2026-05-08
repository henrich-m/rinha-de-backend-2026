# frozen_string_literal: true

require "minitest/autorun"
require_relative "../src/vectorizer"

class VectorizationTest < Minitest::Test
  def setup
    @v = Vectorizer.new("resources/normalization.json", "resources/mcc_risk.json")
  end

  LEGIT_PAYLOAD = {
    "transaction" => { "amount" => 41.12, "installments" => 2, "requested_at" => "2026-03-11T18:45:53Z" },
    "customer"    => { "avg_amount" => 82.24, "tx_count_24h" => 3, "known_merchants" => ["MERC-003", "MERC-016"] },
    "merchant"    => { "id" => "MERC-016", "mcc" => "5411", "avg_amount" => 60.25 },
    "terminal"    => { "is_online" => false, "card_present" => true, "km_from_home" => 29.23 },
    "last_transaction" => nil
  }.freeze

  EXPECTED_LEGIT = [0.0041, 0.1667, 0.05, 0.7826, 0.3333, -1, -1, 0.0292, 0.15, 0, 1, 0, 0.15, 0.006].freeze

  FRAUD_PAYLOAD = {
    "transaction" => { "amount" => 9505.97, "installments" => 10, "requested_at" => "2026-03-14T05:15:12Z" },
    "customer"    => { "avg_amount" => 81.28, "tx_count_24h" => 20, "known_merchants" => ["MERC-008", "MERC-007", "MERC-005"] },
    "merchant"    => { "id" => "MERC-068", "mcc" => "7802", "avg_amount" => 54.86 },
    "terminal"    => { "is_online" => false, "card_present" => true, "km_from_home" => 952.27 },
    "last_transaction" => nil
  }.freeze

  EXPECTED_FRAUD = [0.9506, 0.8333, 1.0, 0.2174, 0.8333, -1, -1, 0.9523, 1.0, 0, 1, 1, 0.75, 0.0055].freeze

  def test_legit_vector_dimensions
    result = @v.vectorize(LEGIT_PAYLOAD)
    assert_equal 14, result.length
  end

  def test_legit_vector_values
    result = @v.vectorize(LEGIT_PAYLOAD)
    EXPECTED_LEGIT.each_with_index do |expected, i|
      assert_in_delta expected, result[i], 0.001, "legit dim #{i} mismatch"
    end
  end

  def test_fraud_vector_values
    result = @v.vectorize(FRAUD_PAYLOAD)
    EXPECTED_FRAUD.each_with_index do |expected, i|
      assert_in_delta expected, result[i], 0.001, "fraud dim #{i} mismatch"
    end
  end

  def test_null_last_transaction_sets_sentinel
    result = @v.vectorize(LEGIT_PAYLOAD)
    assert_equal(-1, result[5], "index 5 must be -1 when last_transaction is null")
    assert_equal(-1, result[6], "index 6 must be -1 when last_transaction is null")
  end

  def test_values_clamped_to_unit_range
    result = @v.vectorize(FRAUD_PAYLOAD)
    non_sentinel = result.reject.with_index { |_, i| [5, 6].include?(i) }
    non_sentinel.each_with_index do |val, i|
      assert_operator val, :>=, 0.0, "dim #{i} below 0"
      assert_operator val, :<=, 1.0, "dim #{i} above 1"
    end
  end
end
