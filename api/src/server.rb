# frozen_string_literal: true

require "roda"
require "oj"

class App < Roda
  route do |r|
    r.get "ready" do
      if KNN.ready?
        response.status = 200
        "Ready"
      else
        response.status = 503
        "Loading"
      end
    end

    r.post "fraud-score" do
      response["Content-Type"] = "application/json"
      payload     = Oj.load(r.body.read, symbol_keys: false)
      vector      = VECTORIZER.vectorize(payload)
      labels      = KNN.search(vector, k: 5)
      fraud_count = labels.count { |v| v == 1 }
      fraud_score = fraud_count.to_f / 5
      Oj.dump({ "approved" => fraud_score < 0.6, "fraud_score" => fraud_score })
    rescue
      Oj.dump({ "approved" => true, "fraud_score" => 0.0 })
    end
  end
end
