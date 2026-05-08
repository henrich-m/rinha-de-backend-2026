# frozen_string_literal: true

require "async/io"
# protocol-rack calls peer.ip_address; async-io sockets only expose remote_address
Async::IO::Socket.prepend(Module.new { def ip_address = remote_address.ip_address })

require_relative "src/server"
run App
