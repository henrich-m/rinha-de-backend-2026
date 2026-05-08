# frozen_string_literal: true

require "roda"
require "oj"

class App < Roda
  route do |r|
    r.get "ready" do
      if DB.ready?
        response.status = 200
        ""
      else
        response.status = 503
        ""
      end
    end

    r.post "fraud-score" do
      Oj.load(r.body.read, symbol_keys: false)
      response["Content-Type"] = "application/json"
      Oj.dump({ "approved" => true, "fraud_score" => 0.0 })
    end
  end
end
