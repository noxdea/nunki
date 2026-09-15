# frozen_string_literal: true

module Nunki
  module Providers
    class OpenAI < Provider
      def self.headers(api_key)
        api_key ? {"Authorization" => "Bearer #{Protocol.string(api_key, "api_key", empty: false, max: 8192)}"} : {}
      end

      private

      def perform_complete(prepared)
        messages, tools, system, max_tokens = prepared
        messages = [Message.new(role: :system, content: [text_part(system)])] + messages if system
        payload = {
          model: @model,
          messages: messages.map { |message| encode_message(message) },
          max_tokens: max_tokens,
          stream: true
        }
        payload[:tools] = tools.map { |tool| encode_tool(tool) } unless tools.empty?

        state = {text: +"", tools: {}, finish: nil, usage: nil}
        result = @client.post_json(payload, headers: {"Accept" => "text/event-stream, application/json"}) do |event|
          next if event.data.empty? || event.data == "[DONE]"
          consume_stream(parse_event(event), state) { |part| yield part if block_given? }
        end
        return consume_response(result.body, messages) unless result.body.empty?

        parts = []
        parts << text_part(state[:text]) unless state[:text].empty?
        state[:tools].sort.each do |_index, tool|
          part = tool_part(tool[:name], parse_tool_input(tool[:arguments]), tool[:id])
          parts << part
          yield part if block_given?
        end
        usage = state[:usage] || [Nunki.estimate_tokens(messages), Nunki.estimate_tokens(parts)]
        response(parts, usage, state[:finish])
      end

      def consume_stream(message, state)
        usage = message["usage"]
        usage = Protocol.object(usage, "usage") if usage
        state[:usage] = [usage["prompt_tokens"], usage["completion_tokens"]].map { |v| Protocol.uint(v, "usage") } if usage

        Protocol.collection(message.fetch("choices", []), "choices").each do |choice|
          choice = Protocol.object(choice, "choice")
          state[:finish] = Protocol.string(choice["finish_reason"], "finish reason") if choice["finish_reason"]
          delta = Protocol.object(choice.fetch("delta", {}), "delta")
          if delta["content"]
            text = Protocol.string(delta["content"], "content delta")
            state[:text] << text
            yield text_part(text)
          end
          consume_tool_deltas(delta["tool_calls"], state) if delta["tool_calls"]
        end
      end

      def consume_tool_deltas(calls, state)
        Protocol.collection(calls, "tool calls").each do |call|
          call = Protocol.object(call, "tool call")
          index = Protocol.uint(call["index"], "tool call index")
          tool = state[:tools][index] ||= {id: nil, name: +"", arguments: +""}
          tool[:id] = Protocol.string(call["id"], "tool call id") if call["id"]
          function = Protocol.object(call.fetch("function", {}), "tool function")
          tool[:name] << Protocol.string(function["name"], "tool name") if function["name"]
          tool[:arguments] << Protocol.string(function["arguments"], "tool arguments") if function["arguments"]
        end
      end

      def consume_response(body, messages)
        message = Protocol.object(Protocol.parse(body), "response")
        choice = Protocol.object(Protocol.collection(message["choices"], "choices").first, "choice")
        value = Protocol.object(choice["message"], "message")
        parts = []
        parts << text_part(Protocol.string(value["content"], "content")) if value["content"]
        consume_nonstream_tools(value["tool_calls"], parts) if value["tool_calls"]
        usage = message["usage"]
        usage = Protocol.object(usage, "usage") if usage
        counts = usage ? [usage["prompt_tokens"], usage["completion_tokens"]].map { |v| Protocol.uint(v, "usage") } :
          [Nunki.estimate_tokens(messages), Nunki.estimate_tokens(parts)]
        finish = choice["finish_reason"] && Protocol.string(choice["finish_reason"], "finish reason")
        response(parts, counts, finish)
      end

      def consume_nonstream_tools(calls, parts)
        Protocol.collection(calls, "tool calls").each do |call|
          call = Protocol.object(call, "tool call")
          function = Protocol.object(call["function"], "tool function")
          parts << tool_part(
            Protocol.string(function["name"], "tool name", empty: false),
            parse_tool_input(Protocol.string(function["arguments"], "tool arguments")),
            Protocol.string(call["id"], "tool id", empty: false)
          )
        end
      end

      def encode_message(message)
        role = message.role.to_s
        text = message.content.select { |part| part.type.to_s.to_sym == :text }.map(&:text).join
        results = message.content.select { |part| part.type.to_s.to_sym == :tool_result }
        if results.any?
          raise ProtocolError, "OpenAI tool result messages must contain exactly one result" unless results.one? && text.empty?
          return {role: "tool", tool_call_id: results.first.tool_use_id, content: results.first.text}
        end

        encoded = {role: role, content: text.empty? ? nil : text}
        calls = message.content.select { |part| part.type.to_s.to_sym == :tool_use }
        encoded[:tool_calls] = calls.map do |part|
          {id: part.tool_use_id, type: "function", function: {name: part.tool_name, arguments: JSON.generate(part.tool_input)}}
        end unless calls.empty?
        encoded
      end

      def encode_tool(tool)
        {type: "function", function: {name: tool.name, description: tool.description, parameters: tool.input_schema}}
      end

      def parse_tool_input(json)
        Protocol.object(Protocol.parse(json, "tool input"), "tool input")
      end
    end
  end
end
