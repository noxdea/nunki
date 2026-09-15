# frozen_string_literal: true

module Nunki
  module SSE
    Event = Value.define(:event, :data, :id, :retry)

    class Parser
      DEFAULT_MAX_EVENT_BYTES = 1_048_576

      def initialize(max_event_bytes: DEFAULT_MAX_EVENT_BYTES)
        @max_event_bytes = Protocol.uint(max_event_bytes, "max_event_bytes", positive: true)
        @buffer = +""
        reset_event
      end

      def feed(chunk)
        raise ProtocolError, "SSE chunk must be a string" unless chunk.is_a?(String)
        @buffer << chunk
        events = []
        while (newline = @buffer.index("\n"))
          line = @buffer.slice!(0, newline + 1).delete_suffix("\n").delete_suffix("\r")
          consume(line, events)
        end
        raise ProtocolError, "SSE event exceeds #{@max_event_bytes} bytes" if event_bytes > @max_event_bytes
        events
      end

      def finish
        events = []
        consume(@buffer.delete_suffix("\r"), events) unless @buffer.empty?
        dispatch(events) if @seen
        @buffer.clear
        events
      end

      private

      def consume(line, events)
        if line.empty?
          dispatch(events)
          return
        end
        return if line.start_with?(":")

        field, value = line.split(":", 2)
        value = value&.delete_prefix(" ") || ""
        @seen = true
        case field
        when "event" then @event = value
        when "data" then @data << value
        when "id" then @id = value unless value.include?("\0")
        when "retry" then @retry = Integer(value, exception: false) if value.match?(/\A\d+\z/)
        end
      end

      def dispatch(events)
        return reset_event unless @seen

        events << Event.new(event: @event, data: @data.join("\n"), id: @id, retry: @retry)
        reset_event
      end

      def reset_event
        @event = nil
        @data = []
        @id = nil
        @retry = nil
        @seen = false
      end

      def event_bytes = @buffer.bytesize + @data.sum(&:bytesize)
    end
  end
end
