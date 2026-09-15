# frozen_string_literal: true

module Nunki
  module Context
    module_function

    def estimate_tokens(value)
      case value
      when Message
        estimate_string(value.role.to_s) + estimate_tokens(value.content)
      when Part
        estimate_string([value.type, value.text, value.tool_name, value.tool_input, value.tool_use_id].compact.join)
      when Array
        value.sum { |item| estimate_tokens(item) }
      else
        estimate_string(value.to_s)
      end
    end

    def truncate(messages, max_tokens:)
      Protocol.uint(max_tokens, "max_tokens", positive: true)
      messages = Protocol.collection(messages, "messages")
      validate_messages(messages)

      kept = messages.dup
      kept.shift while kept.length > 1 && estimate_tokens(kept) > max_tokens
      raise ProtocolError, "latest message exceeds token budget" if estimate_tokens(kept) > max_tokens

      kept.freeze
    end

    def validate_messages(messages)
      messages.each do |message|
        raise ProtocolError, "message must be a Nunki::Message" unless message.is_a?(Message)
        role = Protocol.string(message.role.to_s, "message role", empty: false, max: 32)
        raise ProtocolError, "unsupported message role: #{role}" unless %w[system user assistant tool].include?(role)
        Protocol.collection(message.content, "message content").each do |part|
          raise ProtocolError, "message content must contain Nunki::Part values" unless part.is_a?(Part)
          validate_part(part)
        end
      end
    end

    def validate_part(part)
      case part.type.to_s.to_sym
      when :text
        Protocol.string(part.text, "text part")
      when :tool_use
        Protocol.string(part.tool_name, "tool name", empty: false, max: 256)
        Protocol.string(part.tool_use_id, "tool use id", empty: false, max: 1024)
        Protocol.json(Protocol.object(part.tool_input, "tool input"))
      when :tool_result
        Protocol.string(part.tool_use_id, "tool use id", empty: false, max: 1024)
        Protocol.string(part.text, "tool result")
      else
        raise ProtocolError, "unsupported part type: #{part.type}"
      end
    end

    def estimate_string(text) = [(text.bytesize + 3) / 4, 1].max
  end

  def self.estimate_tokens(value) = Context.estimate_tokens(value)
  def self.truncate(messages, max_tokens:) = Context.truncate(messages, max_tokens: max_tokens)
end
