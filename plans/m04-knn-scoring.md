# M04 — KNN scoring via pgvector

## Goal

`POST /fraud-score` returns the correct `approved` and `fraud_score` by querying postgres for the 5 nearest neighbors using the pgvector `<->` (L2) operator. Results must match the two canonical examples in DETECTION_RULES.md.

## Tasks

1. In `src/db.rb`, add a `knn(vector, k: 5)` method:
   ```ruby
   sql = "SELECT is_fraud FROM refs ORDER BY embedding <-> $1::vector LIMIT $2"
   DB.query(sql, ["[#{vector.join(',')}]", k])
   ```
   The `$1::vector` explicit cast works with `pg`'s text-protocol bind parameters — no OID override needed. `DB.query` returns a `PG::Result`; PostgreSQL returns booleans as the strings `"t"` / `"f"`.
2. In `src/server.rb`, wire the `/fraud-score` route:
   - Parse payload → `Vectorizer#vectorize` → `DB#knn` → count frauds → return score.
   - `fraud_count = result.count { |row| row["is_fraud"] == "t" }`
   - `fraud_score = fraud_count.to_f / 5`
   - `approved = fraud_score < 0.6`
3. Return `{ "approved": bool, "fraud_score": float }` as JSON via `oj`.
4. Use a small pool of 2–4 `Async::Postgres::Client` instances per API process — a single client serializes concurrent fiber queries (PostgreSQL's wire protocol is request-response, not multiplexed). Match the pool size to PgBouncer's `default_pool_size`.
5. Update `CLAUDE.md`: document the pgvector query pattern, boolean string convention (`"t"`/`"f"`), the `fraud_score < 0.6` threshold, and the end-to-end request flow (HTTP → vectorize → pgvector query → response).

## Acceptance criteria

Run with: `bundle exec ruby -Itest test/m04_knn_scoring_test.rb` (server must be running on port 9999 with database loaded).

```ruby
# test/m04_knn_scoring_test.rb
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
```
