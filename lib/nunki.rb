# frozen_string_literal: true

require_relative "nunki/version"

module Nunki
  class Error < StandardError; end
  class ProtocolError < Error; end
  class Timeout < Error; end
  class Cancelled < Error; end

  class HTTPError < Error
    attr_reader :status, :body

    def initialize(status, body = nil)
      @status = status
      @body = body
      super("HTTP request failed with status #{status}")
    end
  end

  class RateLimited < HTTPError
    attr_reader :retry_after

    def initialize(body = nil, retry_after: nil)
      @retry_after = retry_after
      super(429, body)
    end
  end

  module Value
    module_function

    def define(*members)
      return Data.define(*members) if defined?(Data) && Data.respond_to?(:define)

      Struct.new(*members) do
        members.each { |member| undef_method("#{member}=") }

        define_method(:initialize) do |*values, **keywords|
          raise ArgumentError, "cannot mix positional and keyword arguments" if values.any? && keywords.any?

          values = self.class.members.map { |member| keywords.fetch(member) } if keywords.any?
          super(*values)
          freeze
        end

        define_method(:with) { |**changes| self.class.new(**to_h.merge(changes)) }
      end
    end
  end

  Message = Value.define(:role, :content)
  Part = Value.define(:type, :text, :tool_name, :tool_input, :tool_use_id)
  Tool = Value.define(:name, :description, :input_schema)
  Usage = Value.define(:input_tokens, :output_tokens)
  Response = Value.define(:message, :usage, :finish_reason)
  private_constant :Value
end

require_relative "nunki/protocol"
require_relative "nunki/context"
require_relative "nunki/sse"
require_relative "nunki/http"
require_relative "nunki/provider"
require_relative "nunki/providers/open_ai"
require_relative "nunki/providers/anthropic"
require_relative "nunki/mcp"
