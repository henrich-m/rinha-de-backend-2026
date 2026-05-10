# frozen_string_literal: true
require_relative "src/knn"
KNN = Knn.new(
  File.expand_path("index.faiss", __dir__),
  File.expand_path("labels.bin",  __dir__)
)

require_relative "src/search_server"
run SearchApp
