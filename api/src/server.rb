# frozen_string_literal: true

require "roda"
require "oj"
require "async/http/client"
require "async/http/endpoint"

module Search
  def self.client
    @client ||= Async::HTTP::Client.new(
      Async::HTTP::Endpoint.parse(SEARCH_URL),
      protocol: Async::HTTP::Protocol::HTTP1
    )
  end

  def self.ready?
    client.get("/ready")
  end

  def self.knn(vector)
    resp = client.post("/knn",
      [["content-type", "application/octet-stream"]],
      [vector.pack("e14")]
    )
    resp.read.unpack("C5")
  end
end

class App < Roda
  route do |r|
    r.get "ready" do
      resp = Search.ready?
      response.status = resp.status
      resp.read
    rescue
      response.status = 503
      "Search not ready"
    end

    r.post "fraud-score" do
      response["Content-Type"] = "application/json"
      payload = Oj.load(r.body.read, symbol_keys: false)
      vector  = VECTORIZER.vectorize(payload)
      begin
        labels      = Search.knn(vector)
        fraud_count = labels.count { |v| v == 1 }
        fraud_score = fraud_count.to_f / 5
        Oj.dump({ "approved" => fraud_score < 0.6, "fraud_score" => fraud_score })
      rescue
        Oj.dump({ "approved" => true, "fraud_score" => 0.0 })
      end
    end
  end
end
