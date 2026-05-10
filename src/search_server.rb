# frozen_string_literal: true
require "roda"
require "oj"

class SearchApp < Roda

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

    r.post "knn" do
      body    = Oj.load(r.body.read, symbol_keys: false)
      results = KNN.search(body["vector"], k: body.fetch("k", 5))
      Oj.dump({ "results" => results })
    end
  end
end
