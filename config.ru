# frozen_string_literal: true

# pg 1.6.3 Ruby 4 compatibility: the Ruby 4 C extension no longer defines
# PG::Connection::Pollable or PG.make_shareable, but the pg Ruby files still
# reference them. Pre-load the extension and fill in the missing pieces so
# the subsequent full require "pg" (triggered by Db.new) succeeds.
# begin
#   require "#{RUBY_VERSION[/\d+\.\d+/]}/pg_ext"
# rescue LoadError
#   require "pg_ext"
# end
# PG::Connection::Pollable = Module.new unless PG::Connection.const_defined?(:Pollable)
# PG.instance_eval { def make_shareable(obj) = obj.freeze } unless PG.respond_to?(:make_shareable)
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
