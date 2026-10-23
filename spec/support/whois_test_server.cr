require "socket"

# A loopback-only WHOIS fixture for the whois client/module specs. It binds
# 127.0.0.1 on an ephemeral port, never a routable interface. A query with no
# dot (a bare TLD, the IANA referral probe) is answered with a "whois:" line
# pointing back at the fixture; a dotted query (the domain itself) gets the
# supplied record. So one listener stands in for both whois.iana.org and the
# authoritative server the client is pointed at with its injected port.
module WhoisTestServer
  extend self

  def with_server(record : String, referral_host : String = "127.0.0.1", &block : Int32 ->) : Nil
    server = TCPServer.new("127.0.0.1", 0)
    port = server.local_address.port
    spawn { serve(server, record, referral_host) }
    begin
      block.call(port)
    ensure
      server.close rescue nil
    end
  end

  private def serve(server : TCPServer, record : String, referral_host : String) : Nil
    loop do
      socket = server.accept
      spawn { handle(socket, record, referral_host) }
    end
  rescue
    # the listener was closed at teardown
  end

  private def handle(socket : TCPSocket, record : String, referral_host : String) : Nil
    query = socket.gets || ""
    socket.print(query.includes?('.') ? record : "whois: #{referral_host}\r\n")
    socket.flush
  ensure
    socket.close rescue nil
  end
end
