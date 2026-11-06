# connect_timeout: is nil at run time: no deadline, as in CRuby, wherever the
# nil comes from. Only a literal nil was seen as one; a local or a parameter
# holding it went to the Float conversion and raised TypeError.
require "socket"

srv = TCPServer.new("127.0.0.1", 0)
port = srv.addr[1]

def connect(port, t)
  s = TCPSocket.new("127.0.0.1", port, connect_timeout: t)
  puts "connected: #{s.is_a?(TCPSocket)}"
  s.close
end

# one type or nil, chosen at run time
far = ARGV.size > 5
connect(port, far ? 5 : nil)
connect(port, far ? 1.5 : nil)
connect(port, far ? "x" : nil)

# locals: always nil, and Float or Integer or nil
a = nil
s = TCPSocket.new("127.0.0.1", port, connect_timeout: a)
puts "nil local: #{s.is_a?(TCPSocket)}"
s.close
b = far ? 2.0 : nil
s = TCPSocket.new("127.0.0.1", port, connect_timeout: b)
puts "Float or nil: #{s.is_a?(TCPSocket)}"
s.close
c = far ? 2 : nil
s = TCPSocket.new("127.0.0.1", port, connect_timeout: c)
puts "Integer or nil: #{s.is_a?(TCPSocket)}"
s.close

# the same slots holding a value still connect under a deadline
near = ARGV.size < 5
d = near ? 5 : nil
s = TCPSocket.new("127.0.0.1", port, connect_timeout: d)
puts "Integer held: #{s.is_a?(TCPSocket)}"
s.close
e = near ? 2.5 : nil
s = TCPSocket.new("127.0.0.1", port, connect_timeout: e)
puts "Float held: #{s.is_a?(TCPSocket)}"
s.close
f = near ? Rational(5, 2) : nil
s = TCPSocket.new("127.0.0.1", port, connect_timeout: f)
puts "Rational held: #{s.is_a?(TCPSocket)}"
s.close

# the timeout is read once
def once
  puts "read once"
  nil
end
s = TCPSocket.new("127.0.0.1", port, connect_timeout: once)
puts "call: #{s.is_a?(TCPSocket)}"
s.close

# a refusal under a nil is still Errno::ECONNREFUSED
srv.close
g = far ? 2 : nil
begin
  TCPSocket.new("127.0.0.1", port, connect_timeout: g)
  puts "refused: connected"
rescue Errno::ECONNREFUSED
  puts "refused: ECONNREFUSED"
end
