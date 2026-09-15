# frozen_string_literal: true

module Nunki
  module Providers
    class Anthropic < Provider
      def self.headers(api_key)
        api_key ? {"x-api-key" => Protocol.string(api_key, "api_key", empty: false, max: 8192)} : {}
      end

      def initialize(client:, model:, api_version: "2023-06-01", **options)
        super(client: client, model: model, **options)
        @api_version = Protocol.string(api_version, "api_version", empty: false, max: 64)
      end

      private

      def perform_complete(prepared)
        messages, tools, system, max_tokens = prepared
        payload = {model: @model, messages: messages.map { |message| encode_message(message) }, max_tokens: max_tokens, stream: true}
        payload[:system] = system if system
        payload[:tools] = tools.map { |tool| encode_tool(tool) } unless tools.empty?
        state = {parts: [], active: {}, usage: [0, 0], finish: nil}

        result = @client.post_json(payload, headers: {
          "Accept" => "text/event-stream, application/json",
          "anthropic-version" => @api_version
        }) do |event|
          next if event.data.empty?
          consume_stream(parse_event(event), state) { |part| yield part if block_given? }
        end
        return consume_response(result.body, messages) unless result.body.empty?

        usage = state[:usage]
        usage[0] = Nunki.estimate_tokens(messages) if usage[0].zero?
        usage[1] = Nunki.estimate_tokens(state[:parts]) if usage[1].zero?
        response(state[:parts], usage, state[:finish])
      end

      def consume_stream(message, state)
        case message["type"]
        when "message_start"
          usage = Protocol.object(Protocol.object(message["message"], "message")["usage"], "usage")
          state[:usage][0] = Protocol.uint(usage.fetch("input_tokens", 0), "input tokens")
        when "content_block_start"
          start_block(message, state) { |part| yield part }
        when "content_block_delta"
          consume_delta(message, state) { |part| yield part }
        when "content_block_stop"
          finish_block(message, state) { |part| yield part }
        when "message_delta"
          delta = Protocol.object(message["delta"], "message delta")
          state[:finish] = Protocol.string(delta["stop_reason"], "stop reason") if delta["stop_reason"]
          usage = Protocol.object(message.fetch("usage", {}), "usage")
          state[:usage][1] = Protocol.uint(usage["output_tokens"], "output tokens") if usage["output_tokens"]
        when "error"
          error = Protocol.object(message["error"], "error")
          raise Error, Protocol.string(error["message"], "error message")
        end
      end

      def start_block(message, state)
        index = Protocol.uint(message["index"], "content index")
        block = Protocol.object(message["content_block"], "content block")
        case block["type"]
        when "text"
          text = Protocol.string(block.fetch("text", ""), "text")
          state[:active][index] = {type: :text, text: +text}
          yield text_part(text) unless text.empty?
        when "tool_use"
          state[:active][index] = {
            type: :tool_use,
            id: Protocol.string(block["id"], "tool id", empty: false),
            name: Protocol.string(block["name"], "tool name", empty: false),
            input: block["input"], json: +""
          }
        end
      end

      def consume_delta(message, state)
        index = Protocol.uint(message["index"], "content index")
        block = state[:active][index]
        return unless block
        delta = Protocol.object(message["delta"], "content delta")
        if delta["type"] == "text_delta"
          text = Protocol.string(delta["text"], "text delta")
          block[:text] << text
          yield text_part(text)
        elsif delta["type"] == "input_json_delta"
          block[:json] << Protocol.string(delta["partial_json"], "tool input delta")
        end
      end

      def finish_block(message, state)
        block = state[:active].delete(Protocol.uint(message["index"], "content index"))
        return unless block
        if block[:type] == :text
          state[:parts] << text_part(block[:text]) unless block[:text].empty?
        else
          input = block[:json].empty? ? Protocol.object(block[:input], "tool input") :
            Protocol.object(Protocol.parse(block[:json], "tool input"), "tool input")
          part = tool_part(block[:name], input, block[:id])
          state[:parts] << part
          yield part
        end
      end

      def consume_response(body, messages)
        value = Protocol.object(Protocol.parse(body), "response")
        parts = Protocol.collection(value["content"], "content").map { |part| decode_part(part) }
        usage = Protocol.object(value.fetch("usage", {}), "usage")
        counts = [
          usage["input_tokens"] ? Protocol.uint(usage["input_tokens"], "input tokens") : Nunki.estimate_tokens(messages),
          usage["output_tokens"] ? Protocol.uint(usage["output_tokens"], "output tokens") : Nunki.estimate_tokens(parts)
        ]
        response(parts, counts, value["stop_reason"])
      end

      def decode_part(value)
        value = Protocol.object(value, "content part")
        return text_part(Protocol.string(value["text"], "text")) if value["type"] == "text"
        raise ProtocolError, "unsupported content type" unless value["type"] == "tool_use"
        tool_part(
          Protocol.string(value["name"], "tool name", empty: false),
          Protocol.object(value["input"], "tool input"),
          Protocol.string(value["id"], "tool id", empty: false)
        )
      end

      def encode_message(message)
        {role: message.role.to_s, content: message.content.map { |part| encode_part(part) }}
      end

      def encode_part(part)
        case part.type.to_s.to_sym
        when :text then {type: "text", text: part.text}
        when :tool_use then {type: "tool_use", id: part.tool_use_id, name: part.tool_name, input: part.tool_input}
        when :tool_result then {type: "tool_result", tool_use_id: part.tool_use_id, content: part.text}
        else raise ProtocolError, "unsupported part type: #{part.type}"
        end
      end

      def encode_tool(tool)
        {name: tool.name, description: tool.description, input_schema: tool.input_schema}
      end
    end
  end
end
