# frozen_string_literal: true

require "falcon/environment/server"
require "falcon/environment/rackup"
require "async/http/protocol"

service "search" do
  include Falcon::Environment::Server
  include Falcon::Environment::Rackup

  count 1

  endpoint do
    ::Falcon::ProxyEndpoint.unix(
      ENV.fetch("SOCKET_PATH", "/run/search/search.sock"),
      protocol: Async::HTTP::Protocol::HTTP1,
      scheme:   "http",
      authority: "localhost"
    )
  end
end
