# frozen_string_literal: true

require "open3"

module Nunki
  module MCP
    module Transports
      class Stdio
        MAX_MESSAGE_BYTES = 4_194_304

        def initialize(command:, env: {})
          @command = validate_command(command)
          @env = validate_env(env)
          @request_lock = Mutex.new
          @write_lock = Mutex.new
          @buffer = +""
          @closed = false
        end

        def protocol_version=(_version); end

        def request(message, timeout:)
          @request_lock.synchronize do
            ensure_open
            write(message)
            deadline = monotonic + timeout
            loop do
              response = read_message(deadline)
              return response if response["id"] == message["id"]
              reply_to_server(response) if response["method"] && response.key?("id")
            end
          end
        end

        def notify(message)
          ensure_open
          write(message)
          nil
        rescue Error, IOError, SystemCallError
          nil
        end

        def close
          return if @closed
          @closed = true
          @stdin&.close unless @stdin&.closed?
          stop_process
          [@stdout, @stderr].compact.each { |io| io.close unless io.closed? }
          @stderr_thread&.join(0.2)
          nil
        end

        private

        def ensure_open
          raise Error, "MCP transport is closed" if @closed
          return if @waiter

          @stdin, @stdout, @stderr, @waiter = Open3.popen3(@env, *@command)
          @stdin.binmode
          @stdout.binmode
          @stderr_thread = Thread.new do
            loop { break unless @stderr.read(16_384) }
          rescue IOError
            nil
          end
        rescue SystemCallError => error
          raise Error, "failed to start MCP server: #{error.message}"
        end

        def write(message)
          source = JSON.generate(Protocol.json(message))
          raise ProtocolError, "MCP message exceeds #{MAX_MESSAGE_BYTES} bytes" if source.bytesize > MAX_MESSAGE_BYTES
          @write_lock.synchronize do
            @stdin.write(source, "\n")
            @stdin.flush
          end
        end

        def read_message(deadline)
          loop do
            if (newline = @buffer.index("\n"))
              source = @buffer.slice!(0, newline + 1).delete_suffix("\n").delete_suffix("\r")
              next if source.empty?
              return Protocol.object(Protocol.parse(source, "MCP message"), "MCP message")
            end
            wait = deadline - monotonic
            raise Timeout, "MCP request timed out" unless wait.positive? && IO.select([@stdout], nil, nil, wait)
            chunk = @stdout.read_nonblock(16_384, exception: false)
            raise Error, "MCP server closed its output" if chunk.nil?
            next if chunk == :wait_readable
            @buffer << chunk
            raise ProtocolError, "MCP message exceeds #{MAX_MESSAGE_BYTES} bytes" if @buffer.bytesize > MAX_MESSAGE_BYTES
          end
        end

        def reply_to_server(message)
          result = message["method"] == "ping" ? {} : nil
          reply = {"jsonrpc" => "2.0", "id" => message["id"]}
          if result
            reply["result"] = result
          else
            reply["error"] = {"code" => -32_601, "message" => "Method not found"}
          end
          write(reply)
        end

        def stop_process
          return unless @waiter
          return if @waiter.join(0.5)
          Process.kill("TERM", @waiter.pid)
          return if @waiter.join(0.5)
          Process.kill("KILL", @waiter.pid)
          @waiter.join(0.5)
        rescue Errno::ESRCH, Errno::ECHILD
          nil
        end

        def validate_command(command)
          raise ProtocolError, "command must be a non-empty array" unless command.is_a?(Array) && command.any?
          command.map { |part| Protocol.string(part, "command argument", empty: false, max: 32_768) }.freeze
        end

        def validate_env(env)
          raise ProtocolError, "env must be an object" unless env.is_a?(Hash)
          env.to_h do |key, value|
            [Protocol.string(key, "environment name", empty: false, max: 1024),
              Protocol.string(value, "environment value", max: 32_768)]
          end.freeze
        end

        def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      class HTTP
        def initialize(url:, headers: {}, **options)
          @client = Nunki::HTTP::Client.new(endpoint: url, headers: headers, **options)
          @session_id = nil
          @protocol_version = nil
        end

        def protocol_version=(version)
          @protocol_version = version
        end

        def request(message, timeout:)
          response = @client.post_json(message, headers: request_headers)
          @session_id ||= response.headers["mcp-session-id"]
          messages = response.events.filter_map { |event| parse_message(event.data) }
          messages << parse_message(response.body) unless response.body.empty?
          messages.compact.find { |item| item["id"] == message["id"] } ||
            raise(ProtocolError, "MCP HTTP response did not contain the request id")
        rescue Nunki::Timeout
          raise
        end

        def notify(message)
          @client.post_json(message, headers: request_headers)
          nil
        end

        def close
          @client.delete(headers: request_headers) if @session_id
          @client.cancel
          nil
        rescue HTTPError => error
          raise unless error.status == 405
          nil
        end

        private

        def request_headers
          headers = {"Accept" => "application/json, text/event-stream"}
          headers["MCP-Session-Id"] = @session_id if @session_id
          headers["MCP-Protocol-Version"] = @protocol_version if @protocol_version
          headers
        end

        def parse_message(source)
          return nil if source.empty?
          Protocol.object(Protocol.parse(source, "MCP HTTP response"), "MCP HTTP response")
        end
      end
    end
  end
end
