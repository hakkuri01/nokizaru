require "http/server"

# A loopback-only HTTP fixture for transport specs. It binds 127.0.0.1 on an
# ephemeral port, never a routable interface, so the gate stays off the network.
# The handler proc answers each request; the block receives the base URL.
module HttpTestServer
  extend self

  def with_server(handler : ::HTTP::Server::Context ->, &block : String ->) : Nil
    server = ::HTTP::Server.new { |context| handler.call(context) }
    address = server.bind_tcp("127.0.0.1", 0)
    # A block that makes no request can close the server before the listen fiber
    # is scheduled, and listen raises when it is called after close.
    spawn { server.listen unless server.closed? }
    begin
      block.call("http://127.0.0.1:#{address.port}")
    ensure
      server.close
    end
  end

  # An address that nothing listens on: bind an ephemeral port, then release it.
  def closed_port : Int32
    server = TCPServer.new("127.0.0.1", 0)
    port = server.local_address.port
    server.close
    port
  end
end
