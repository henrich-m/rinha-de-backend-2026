# frozen_string_literal: true

require_relative "src/vectorizer"

VECTORIZER = Vectorizer.new(
  File.expand_path("resources/normalization.json", __dir__),
  File.expand_path("resources/mcc_risk.json", __dir__)
)

SEARCH_SOCKET = ENV.fetch("SEARCH_SOCKET", "/run/search/search.sock")

require_relative "src/server"
run App
