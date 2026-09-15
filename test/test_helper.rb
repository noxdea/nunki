# frozen_string_literal: true

require "minitest/autorun"
require "socket"
require "nunki"

module NunkiTestSupport
  class HTTPServer
    attr_reader :requests, :url

    def initialize(&handler)
      @server = TCPServer.new("127.0.0.1", 0)
      @url = "http://127.0.0.1:#{@server.addr[1]}/api"
      @handler = handler
      @requests = Queue.new
      @thread = Thread.new { serve }
    end

    def close
      @server.close
      @thread.join(1)
    rescue IOError
      nil
    end

    private

    def serve
      loop do
        socket = @server.accept
        request = read_request(socket)
        @requests << request
        status, headers, body = @handler.call(request)
        body ||= ""
        headers = {"Content-Length" => body.bytesize.to_s, "Connection" => "close"}.merge(headers)
        socket.write("HTTP/1.1 #{status}\r\n")
        headers.each { |key, value| socket.write("#{key}: #{value}\r\n") }
        socket.write("\r\n", body)
        socket.close
      end
    rescue IOError, Errno::EBADF
      nil
    end

    def read_request(socket)
      method, path, = socket.gets.split
      headers = {}
      while (line = socket.gets) && line != "\r\n"
        key, value = line.split(":", 2)
        headers[key.downcase] = value.strip
      end
      body = socket.read(headers.fetch("content-length", "0").to_i)
      {method: method, path: path, headers: headers, body: body}
    end
  end

  def text(value)
    Nunki::Part.new(type: :text, text: value, tool_name: nil, tool_input: nil, tool_use_id: nil)
  end

  def nunki_message(role, value)
    Nunki::Message.new(role: role, content: [text(value)])
  end

  def sse(*values)
    values.map { |value| "data: #{value.is_a?(String) ? value : JSON.generate(value)}\n\n" }.join
  end

  def with_server(handler)
    server = HTTPServer.new(&handler)
    yield server
  ensure
    server&.close
  end
end

class Minitest::Test
  include NunkiTestSupport
end
