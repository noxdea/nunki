# frozen_string_literal: true

require "net/http"
require "timeout"
require "uri"

module Nunki
  module HTTP
    Result = Value.define(:status, :headers, :body, :events)

    class Client
      DEFAULT_MAX_REQUEST_BYTES = 1_048_576
      DEFAULT_MAX_RESPONSE_BYTES = 8_388_608
      RETRY_STATUSES = [429, *(500..599)].freeze

      attr_reader :endpoint

      def initialize(endpoint:, headers: {}, open_timeout: 10, read_timeout: 60, retries: 2,
        retry_base: 0.25, max_request_bytes: DEFAULT_MAX_REQUEST_BYTES,
        max_response_bytes: DEFAULT_MAX_RESPONSE_BYTES)
        @endpoint = parse_endpoint(endpoint)
        @headers = validate_headers(headers)
        @open_timeout = positive_number(open_timeout, "open_timeout")
        @read_timeout = positive_number(read_timeout, "read_timeout")
        @retries = Protocol.uint(retries, "retries")
        @retry_base = nonnegative_number(retry_base, "retry_base")
        @max_request_bytes = Protocol.uint(max_request_bytes, "max_request_bytes", positive: true)
        @max_response_bytes = Protocol.uint(max_response_bytes, "max_response_bytes", positive: true)
        @state_lock = Mutex.new
        @state_changed = ConditionVariable.new
        @cancelled = false
        @active = nil
      end

      def post_json(payload, headers: {}, &event_handler)
        body = JSON.generate(Protocol.json(payload))
        raise ProtocolError, "request exceeds #{@max_request_bytes} bytes" if body.bytesize > @max_request_bytes

        request(Net::HTTP::Post, body, headers, &event_handler)
      end

      def delete(headers: {}) = request(Net::HTTP::Delete, nil, headers)

      def cancel
        http = @state_lock.synchronize do
          @cancelled = true
          @state_changed.broadcast
          @active
        end
        http.finish if http&.active?
      rescue IOError, SystemCallError
        nil
      end

      private

      def request(request_class, body, headers)
        reset_cancel
        attempts = 0
        loop do
          response = perform(request_class, body, validate_headers(headers)) { |event| yield event if block_given? }
          if RETRY_STATUSES.include?(response.status) && attempts < @retries
            attempts += 1
            wait_retry(@retry_base * (2**(attempts - 1)))
            next
          end

          raise_http_error(response) unless (200..299).cover?(response.status)
          return response
        end
      rescue ::Timeout::Error => error
        raise Cancelled, "request cancelled" if cancelled?
        raise Timeout, error.message
      rescue IOError, EOFError, SocketError, SystemCallError => error
        raise Cancelled, "request cancelled" if cancelled?
        raise Error, error.message
      ensure
        @state_lock.synchronize { @active = nil }
      end

      def perform(request_class, body, extra_headers)
        raise Cancelled, "request cancelled" if cancelled?

        http = Net::HTTP.new(@endpoint.host, @endpoint.port)
        http.use_ssl = @endpoint.scheme == "https"
        http.open_timeout = @open_timeout
        http.read_timeout = @read_timeout
        @state_lock.synchronize do
          raise Cancelled, "request cancelled" if @cancelled
          @active = http
        end

        request = request_class.new(request_target)
        @headers.merge(extra_headers).each { |key, value| request[key] = value }
        if body
          request["Content-Type"] ||= "application/json"
          request.body = body
        end

        result = nil
        http.start do
          http.request(request) do |response|
            result = read_response(response) { |event| yield event if block_given? }
          end
        end
        result
      end

      def read_response(response)
        headers = response.each_header.to_h.freeze
        parser = SSE::Parser.new(max_event_bytes: @max_response_bytes) if sse?(headers)
        bytes = 0
        body = +""
        events = []

        response.read_body do |chunk|
          raise Cancelled, "request cancelled" if cancelled?
          bytes += chunk.bytesize
          raise ProtocolError, "response exceeds #{@max_response_bytes} bytes" if bytes > @max_response_bytes
          if parser
            parser.feed(chunk).each do |event|
              events << event
              yield event if block_given? && response.is_a?(Net::HTTPSuccess)
            end
          else
            body << chunk
          end
        end
        parser&.finish&.each do |event|
          events << event
          yield event if block_given? && response.is_a?(Net::HTTPSuccess)
        end
        Result.new(status: response.code.to_i, headers: headers, body: body.freeze, events: events.freeze)
      end

      def raise_http_error(result)
        retry_after = Float(result.headers["retry-after"], exception: false)
        raise RateLimited.new(result.body, retry_after: retry_after) if result.status == 429
        raise HTTPError.new(result.status, result.body)
      end

      def wait_retry(seconds)
        @state_lock.synchronize do
          @state_changed.wait(@state_lock, seconds) unless @cancelled || seconds.zero?
          raise Cancelled, "request cancelled" if @cancelled
        end
      end

      def reset_cancel = @state_lock.synchronize { @cancelled = false }
      def cancelled? = @state_lock.synchronize { @cancelled }

      def sse?(headers)
        headers.fetch("content-type", "").downcase.start_with?("text/event-stream")
      end

      def request_target
        path = @endpoint.path.empty? ? "/" : @endpoint.path
        @endpoint.query ? "#{path}?#{@endpoint.query}" : path
      end

      def parse_endpoint(endpoint)
        uri = URI.parse(Protocol.string(endpoint, "endpoint", empty: false, max: 4096))
        valid = %w[http https].include?(uri.scheme) && uri.host && !uri.userinfo && !uri.fragment
        raise ProtocolError, "endpoint must be an HTTP(S) URL without credentials or fragment" unless valid
        uri
      rescue URI::InvalidURIError => error
        raise ProtocolError, "invalid endpoint: #{error.message}"
      end

      def validate_headers(headers)
        raise ProtocolError, "headers must be an object" unless headers.is_a?(Hash)
        headers.to_h do |key, value|
          key = Protocol.string(key.to_s, "header name", empty: false, max: 256)
          value = Protocol.string(value, "header value", max: 8192)
          raise ProtocolError, "headers must not contain newlines" if key.match?(/[\r\n]/) || value.match?(/[\r\n]/)
          [key, value]
        end.freeze
      end

      def positive_number(value, name)
        raise ProtocolError, "#{name} must be positive" unless value.is_a?(Numeric) && value.positive?
        value
      end

      def nonnegative_number(value, name)
        raise ProtocolError, "#{name} must not be negative" unless value.is_a?(Numeric) && value >= 0
        value
      end
    end
  end
end
