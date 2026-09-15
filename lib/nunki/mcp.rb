# frozen_string_literal: true

module Nunki
  module MCP
    PROTOCOL_VERSION = "2025-11-25"

    class RemoteError < Error
      attr_reader :code, :data

      def initialize(code, message, data = nil)
        @code = code
        @data = data
        super(message)
      end
    end

    class Client
      def self.stdio(command:, env: {}, **options)
        timeout = options.delete(:timeout) || 30
        dispatch = options.delete(:dispatch) || ->(&block) { block.call }
        raise ProtocolError, "unknown options: #{options.keys.join(", ")}" unless options.empty?
        new(Transports::Stdio.new(command: command, env: env), timeout: timeout, dispatch: dispatch)
      end

      def self.http(url:, headers: {}, **options)
        timeout = options.delete(:timeout) || 30
        dispatch = options.delete(:dispatch) || ->(&block) { block.call }
        options[:read_timeout] ||= timeout
        options[:retries] = 0 unless options.key?(:retries)
        new(Transports::HTTP.new(url: url, headers: headers, **options), timeout: timeout, dispatch: dispatch)
      end

      attr_reader :capabilities, :server_info

      def initialize(transport, timeout:, dispatch:)
        @transport = transport
        @timeout = positive_timeout(timeout)
        raise ProtocolError, "dispatch must respond to call" unless dispatch.respond_to?(:call)
        @dispatch = dispatch
        @sequence = 0
        @request_lock = Mutex.new
        @state_lock = Mutex.new
        @state = :created
        @capabilities = {}.freeze
        @server_info = {}.freeze
      end

      def start
        @dispatch.call do
          begin_start
          begin
            result = request_now("initialize", {
              protocolVersion: PROTOCOL_VERSION,
              capabilities: {},
              clientInfo: {name: "nunki", version: VERSION}
            }, initializing: true)
            validate_initialization(result)
            @transport.protocol_version = PROTOCOL_VERSION
            @transport.notify(notification("notifications/initialized"))
            @state_lock.synchronize do
              raise Error, "MCP client was closed during initialization" unless @state == :starting
              @state = :started
            end
            result
          rescue StandardError
            close_after_failed_start
            raise
          end
        end
      end

      def tools = schedule { list_all("tools/list", "tools", :tools) }
      def resources = schedule { list_all("resources/list", "resources", :resources) }
      def prompts = schedule { list_all("prompts/list", "prompts", :prompts) }

      def call_tool(name, arguments)
        schedule do
          name = Protocol.string(name, "tool name", empty: false, max: 256)
          arguments = Protocol.object(arguments, "tool arguments")
          result = request_now("tools/call", {name: name, arguments: arguments})
          validate_result_collection(result, "content")
        end
      end

      def read_resource(uri)
        schedule do
          uri = Protocol.string(uri, "resource URI", empty: false, max: 4096)
          result = request_now("resources/read", {uri: uri})
          validate_result_collection(result, "contents")
        end
      end

      def get_prompt(name, arguments = {})
        schedule do
          name = Protocol.string(name, "prompt name", empty: false, max: 256)
          arguments = Protocol.object(arguments, "prompt arguments")
          result = request_now("prompts/get", {name: name, arguments: arguments})
          validate_result_collection(result, "messages")
        end
      end

      def close
        @dispatch.call do
          should_close = @state_lock.synchronize do
            next false if %i[closing closed].include?(@state)
            @state = :closing
            true
          end
          next nil unless should_close
          begin
            @transport.close
          ensure
            @state_lock.synchronize { @state = :closed }
          end
          nil
        end
      end

      private

      def schedule(&block)
        @dispatch.call do
          raise Error, "MCP client is not started" unless @state_lock.synchronize { @state == :started }
          block.call
        end
      end

      def begin_start
        @state_lock.synchronize do
          raise Error, "MCP client has already started" unless @state == :created
          @state = :starting
        end
      end

      def close_after_failed_start
        @transport.close
      rescue StandardError
        nil
      ensure
        @capabilities = {}.freeze
        @server_info = {}.freeze
        @state_lock.synchronize { @state = :closed }
      end

      def request_now(method, params, initializing: false)
        request_id = nil
        @request_lock.synchronize do
          request_id = @sequence += 1
          message = {"jsonrpc" => "2.0", "id" => request_id, "method" => method, "params" => params}
          response = Protocol.object(@transport.request(message, timeout: @timeout), "JSON-RPC response")
          raise ProtocolError, "invalid JSON-RPC version" unless response["jsonrpc"] == "2.0"
          raise ProtocolError, "mismatched JSON-RPC response id" unless response["id"] == request_id
          raise_remote(response["error"]) if response["error"]
          Protocol.deep_freeze(Protocol.object(response["result"], "JSON-RPC result").dup)
        end
      rescue Timeout
        unless initializing
          begin
            @transport.notify(notification("notifications/cancelled", requestId: request_id, reason: "request timed out"))
          rescue StandardError
            nil
          end
        end
        raise
      end

      def validate_initialization(result)
        version = Protocol.string(result["protocolVersion"], "protocol version", empty: false, max: 64)
        raise ProtocolError, "unsupported MCP protocol version: #{version}" unless version == PROTOCOL_VERSION
        @capabilities = Protocol.deep_freeze(Protocol.object(result["capabilities"], "server capabilities").dup)
        @server_info = Protocol.deep_freeze(Protocol.object(result.fetch("serverInfo", {}), "server info").dup)
      end

      def list_all(method, key, capability)
        raise ProtocolError, "server does not advertise #{capability}" unless @capabilities.key?(capability.to_s)
        items = []
        cursor = nil
        100.times do
          result = request_now(method, cursor ? {cursor: cursor} : {})
          values = Protocol.collection(result[key], key)
          values.each { |value| items << validate_descriptor(value, capability) }
          raise ProtocolError, "#{key} list is too large" if items.length > Protocol::MAX_COLLECTION
          cursor = result["nextCursor"]
          break unless cursor
          Protocol.string(cursor, "next cursor", empty: false, max: 4096)
        end
        raise ProtocolError, "#{key} pagination exceeds 100 pages" if cursor
        Protocol.deep_freeze(items)
      end

      def validate_descriptor(value, capability)
        value = Protocol.object(value, "#{capability} descriptor").dup
        key = capability == :resources ? "uri" : "name"
        Protocol.string(value[key], "#{capability} #{key}", empty: false, max: 4096)
        Protocol.object(value["inputSchema"], "tool input schema") if capability == :tools
        value
      end

      def validate_result_collection(result, key)
        Protocol.collection(result[key], key).each { |value| Protocol.json(value) }
        result
      end

      def raise_remote(error)
        error = Protocol.object(error, "JSON-RPC error")
        code = error["code"]
        raise ProtocolError, "JSON-RPC error code must be an integer" unless code.is_a?(Integer)
        message = Protocol.string(error["message"], "JSON-RPC error message", empty: false)
        Protocol.json(error["data"]) if error.key?("data")
        raise RemoteError.new(code, message, error["data"])
      end

      def notification(method, **params)
        message = {"jsonrpc" => "2.0", "method" => method}
        message["params"] = params unless params.empty?
        message
      end

      def positive_timeout(value)
        raise ProtocolError, "timeout must be positive" unless value.is_a?(Numeric) && value.positive?
        value
      end
    end
  end
end

require_relative "mcp/transports"
