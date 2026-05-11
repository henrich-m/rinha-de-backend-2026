# frozen_string_literal: true

require_relative "src/vectorizer"
require_relative "src/knn"

VECTORIZER = Vectorizer.new(
  File.expand_path("resources/normalization.json", __dir__),
  File.expand_path("resources/mcc_risk.json",      __dir__)
)

KNN = Knn.new(
  File.expand_path("index.faiss", __dir__),
  File.expand_path("labels.bin",  __dir__)
)

GC.compact

require_relative "src/server"
run App
