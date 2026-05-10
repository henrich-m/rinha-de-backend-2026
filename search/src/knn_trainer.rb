# frozen_string_literal: true
require "faiss"
require "numo/narray"
require "zlib"
require "oj"

REFS_PATH   = "resources/references.json.gz"
INDEX_PATH  = "index.faiss"
LABELS_PATH = "labels.bin"
NLIST       = 2048
DIM         = 14

vecs   = []
labels = []

Zlib::GzipReader.open(REFS_PATH) do |gz|
  Oj.load(gz, symbol_keys: false).each do |entry|
    vecs   << entry["vector"]
    labels << (entry["label"] == "fraud" ? 1 : 0)
  end
end

matrix    = Numo::SFloat[*vecs]
quantizer = Faiss::IndexFlatL2.new(DIM)
index     = Faiss::IndexIVFFlat.new(quantizer, DIM, NLIST, :l2)
index.train(matrix)
index.add(matrix)
index.save(INDEX_PATH)

File.binwrite(LABELS_PATH, Numo::Int8[*labels].to_binary)

puts "Trained #{NLIST}-cluster IVF index over #{vecs.size} vectors → #{INDEX_PATH}"
