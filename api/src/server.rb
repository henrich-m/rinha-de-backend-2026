# frozen_string_literal: true

require "oj"

App = lambda do |env|
  case [env["REQUEST_METHOD"], env["PATH_INFO"]]
  when ["GET", "/ready"]
    begin
      KNN.ready? ? [200, {}, ["Ready"]] : [503, {}, ["Loading"]]
    rescue
      [503, {}, ["Unavailable"]]
    end
  when ["POST", "/fraud-score"]
    begin
      payload     = Oj.load(env["rack.input"].read, symbol_keys: false)
      vector      = VECTORIZER.vectorize(payload)
      labels      = KNN.search(vector, k: 5)
      fraud_count = labels.count { |v| v == 1 }
      fraud_score = fraud_count.to_f / 5
      body        = Oj.dump({ "approved" => fraud_score < 0.6, "fraud_score" => fraud_score })
      [200, { "Content-Type" => "application/json" }, [body]]
    rescue
      [200, { "Content-Type" => "application/json" },
            [Oj.dump({ "approved" => true, "fraud_score" => 0.0 })]]
    end
  else
    [404, {}, ["Not Found"]]
  end
end
