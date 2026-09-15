# frozen_string_literal: true

module Nunki
  class Provider
    HTTP_OPTIONS = %i[headers open_timeout read_timeout retries retry_base max_request_bytes max_response_bytes].freeze

    def self.build(kind, endpoint:, api_key: nil, model:, **options)
      kind = kind.to_s.tr("-", "_").to_sym
      provider = case kind
      when :openai, :openai_compatible, :local then Providers::OpenAI
      when :anthropic then Providers::Anthropic
      else raise ProtocolError, "unknown provider kind: #{kind}"
      end

      http_options = options.select { |key, _| HTTP_OPTIONS.include?(key) }
      provider_options = options.reject { |key, _| HTTP_OPTIONS.include?(key) }
      headers = http_options.delete(:headers) || {}
      client = HTTP::Client.new(endpoint: endpoint, headers: headers.merge(provider.headers(api_key)), **http_options)
      provider.new(client: client, model: model, **provider_options)
    end

    def initialize(client:, model:, dispatch: ->(&block) { block.call }, context_limit: nil)
      @client = client
      @model = Protocol.string(model, "model", empty: false, max: 256)
      raise ProtocolError, "dispatch must respond to call" unless dispatch.respond_to?(:call)
      @dispatch = dispatch
      @context_limit = context_limit && Protocol.uint(context_limit, "context_limit", positive: true)
      @call_lock = Mutex.new
    end

    def complete(messages, tools: [], system: nil, max_tokens: 1024, &stream)
      @dispatch.call do
        raise Error, "a completion is already in progress" unless @call_lock.try_lock
        begin
          perform_complete(prepare(messages, tools, system, max_tokens), &stream)
        ensure
          @call_lock.unlock
        end
      end
    end

    def cancel = @client.cancel

    private

    def prepare(messages, tools, system, max_tokens)
      Context.validate_messages(Protocol.collection(messages, "messages"))
      tools = validate_tools(Protocol.collection(tools, "tools"))
      system = Protocol.string(system, "system") if system
      max_tokens = Protocol.uint(max_tokens, "max_tokens", positive: true)
      if @context_limit
        raise ProtocolError, "context_limit must exceed max_tokens" unless @context_limit > max_tokens
        messages = Context.truncate(messages, max_tokens: @context_limit - max_tokens)
      end
      [messages, tools, system, max_tokens]
    end

    def validate_tools(tools)
      tools.each do |tool|
        raise ProtocolError, "tool must be a Nunki::Tool" unless tool.is_a?(Tool)
        Protocol.string(tool.name, "tool name", empty: false, max: 256)
        Protocol.string(tool.description, "tool description", max: 16_384)
        Protocol.json(Protocol.object(tool.input_schema, "tool input schema"))
      end
      tools
    end

    def parse_event(event)
      Protocol.object(Protocol.parse(event.data, "SSE data"), "SSE data")
    end

    def response(parts, usage, finish_reason)
      Response.new(
        message: Message.new(role: :assistant, content: parts.freeze),
        usage: Usage.new(input_tokens: usage[0], output_tokens: usage[1]),
        finish_reason: finish_reason
      )
    end

    def text_part(text)
      Part.new(type: :text, text: text, tool_name: nil, tool_input: nil, tool_use_id: nil)
    end

    def tool_part(name, input, id)
      name = Protocol.string(name, "tool name", empty: false, max: 256)
      id = Protocol.string(id, "tool id", empty: false, max: 1024)
      input = Protocol.object(input, "tool input")
      Part.new(type: :tool_use, text: nil, tool_name: name, tool_input: input, tool_use_id: id)
    end
  end

  module Providers; end
end
