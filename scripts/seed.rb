#!/usr/bin/env ruby
# frozen_string_literal: true

require "pg"
require "zlib"
require "oj"

REFS_PATH = File.expand_path("../resources/references.json.gz", __dir__)

conn = PG.connect(ENV.fetch("DATABASE_URL"))

conn.exec("CREATE EXTENSION IF NOT EXISTS vector")
conn.exec(<<~SQL)
  CREATE TABLE IF NOT EXISTS refs (
    id        SERIAL PRIMARY KEY,
    embedding vector(14) NOT NULL,
    is_fraud  BOOLEAN NOT NULL
  )
SQL
conn.exec("TRUNCATE refs")

class SeedHandler < Oj::ScHandler
  # Oj ScHandler builder pattern:
  # - hash_start / array_start return the container object
  # - hash_set(h, key, value) fills the hash
  # - array_append(a, value) appends to the array
  # - array_append with the :outer sentinel streams each completed record to postgres

  def initialize(conn)
    @conn  = conn
    @count = 0
    @depth = 0
  end

  attr_reader :count

  def hash_start = {}
  def hash_end; end
  def hash_key(key) = key
  def hash_set(h, key, value) = h[key] = value

  def array_start
    @depth += 1
    @depth == 1 ? :outer : []
  end

  def array_end
    @depth -= 1
  end

  def array_append(a, value)
    if a == :outer
      is_fraud = value["label"] == "fraud" ? "true" : "false"
      @conn.put_copy_data("[#{value["vector"].join(',')}]\t#{is_fraud}\n")
      @count += 1
      $stderr.print "\r  #{@count} rows..." if (@count % 100_000).zero?
    else
      a << value
    end
  end
end

handler = SeedHandler.new(conn)

conn.copy_data("COPY refs (embedding, is_fraud) FROM STDIN") do
  Zlib::GzipReader.open(REFS_PATH) do |gz|
    Oj.sc_parse(handler, gz)
  end
end

$stderr.puts "\nSeeded #{handler.count} rows."
conn.close
