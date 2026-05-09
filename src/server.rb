# frozen_string_literal: true

require "roda"
require "oj"

class App < Roda
  route do |r|
    r.get "ready" do
      if DB.ready?
        response.status = 200
        "DB Ready"
      else
        response.status = 503
        "DB Not Ready"
      end
    end

    r.post "fraud-score" do
      response["Content-Type"] = "application/json"
      payload     = Oj.load(r.body.read, symbol_keys: false)
      vector      = VECTORIZER.vectorize(payload)
      begin
        neighbors   = DB.knn(vector)
        fraud_count = neighbors.count { |row| row["is_fraud"] == "t" }
        fraud_score = fraud_count.to_f / 5
        Oj.dump({ "approved" => fraud_score < 0.6, "fraud_score" => fraud_score })
      rescue
        puts "."
        Oj.dump({ "approved" => true, "fraud_score" => 0.0 })
      end
    end
  end
end
