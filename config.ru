# frozen_string_literal: true

require "pg"
require_relative "src/db"
DB = Db.new

require_relative "src/vectorizer"
VECTORIZER = Vectorizer.new(
  File.expand_path("resources/normalization.json", __dir__),
  File.expand_path("resources/mcc_risk.json", __dir__)
)

require_relative "src/server"
run App
