# frozen_string_literal: true
require "roda"

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
      vector = r.body.read.unpack("e14")
      results = KNN.search(vector, k: 5)
      response["Content-Type"] = "application/octet-stream"
      results.pack("C5")
    end
  end
end
