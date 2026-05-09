# frozen_string_literal: true

class Db
  # Wraps a PG::Connection as an async-pool resource.
  class PGResource
    attr :concurrency, :count

    def initialize
      @conn        = PG.connect(ENV.fetch("DATABASE_URL"))
      @concurrency = 1
      @count       = 0
      @closed      = false
    end

    def exec_params(sql, params = [])
      @count += 1
      @conn.exec_params(sql, params)
    end

    def viable?
      return false if @closed
      !@conn.finished?
    rescue
      false
    end

    def reusable?
      !@closed && !@conn.finished?
    rescue
      false
    end

    def close
      @closed = true
      @conn.finish
    rescue
      nil
    end
  end

  def initialize(conn: nil)
    # conn is injected in tests to bypass the pool entirely.
    # nil in production — pool is created lazily after Falcon forks.
    @test_conn = conn
  end

  def query(sql, params = [])
    if @test_conn
      @test_conn.exec_params(sql, params)
    else
      pool.acquire { |r| r.exec_params(sql, params) }
    end
  end

  def knn(vector, k: 5)
    query(
      "SELECT is_fraud FROM refs ORDER BY embedding <-> $1::vector LIMIT $2",
      ["[#{vector.join(',')}]", k]
    )
  end

  def ready?
    query("SELECT 1")
    true
  rescue
    false
  end

  private

  def pool
    @pool ||= begin
      require "async/pool/controller"
      Async::Pool::Controller.wrap(limit: 4) { PGResource.new }
    end
  end
end
