# frozen_string_literal: true
require "faiss"
require "numo/narray"

class Knn
  DIM    = 14
  NPROBE = Integer(ENV.fetch("KNN_NPROBE", "64"))

  def initialize(index_path, labels_path)
    @ready        = false
    @index        = Faiss::Index.load(index_path)
    @index.nprobe = NPROBE
    @labels       = Numo::Int8.from_binary(File.binread(labels_path), [@index.ntotal])
    @index.freeze
    @ready        = true
  end

  def ready? = @ready

  # Returns Array of k integers: 1 = fraud, 0 = legit
  def search(vector, k: 5)
    q               = Numo::SFloat[*vector].reshape(1, DIM)
    _dists, indices = @index.search(q, k)
    indices.flatten.to_a.map { |i| @labels[i] }
  end
end
