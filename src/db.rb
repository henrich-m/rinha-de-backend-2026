# frozen_string_literal: true

class Db
  def initialize(conn: nil)
    @conn = conn || begin
      require "pg"
      PG.connect(ENV.fetch("DATABASE_URL"))
    end
  end

  def query(sql, params = [])
    @conn.exec_params(sql, params)
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
end
