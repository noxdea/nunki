# frozen_string_literal: true

require "test_helper"

class ProviderTest < Minitest::Test
  def test_openai_streams_text_and_returns_tool_calls
    chunks = [
      {choices: [{delta: {content: "hello "}}]},
      {choices: [{delta: {content: "world", tool_calls: [{index: 0, id: "call-1", function: {name: "wea", arguments: '{"city"'}}]}}]},
      {choices: [{delta: {tool_calls: [{index: 0, function: {name: "ther", arguments: ':"Tokyo"}'}}]}, finish_reason: "tool_calls"}]},
      {choices: [], usage: {prompt_tokens: 12, completion_tokens: 5}},
      "[DONE]"
    ]
    handler = lambda do |_request|
      ["200 OK", {"Content-Type" => "text/event-stream"}, sse(*chunks)]
    end

    with_server(handler) do |server|
      provider = Nunki::Provider.build(:openai, endpoint: server.url, api_key: "secret", model: "model")
      streamed = []
      response = provider.complete([nunki_message(:user, "weather")], tools: [weather_tool]) { |part| streamed << part }
      request = server.requests.pop

      assert_equal "Bearer secret", request[:headers]["authorization"]
      assert_equal ["hello ", "world"], streamed.select { |part| part.type == :text }.map(&:text)
      assert_equal "hello world", response.message.content[0].text
      assert_equal "weather", response.message.content[1].tool_name
      assert_equal({"city" => "Tokyo"}, response.message.content[1].tool_input)
      assert_equal [12, 5], [response.usage.input_tokens, response.usage.output_tokens]
    end
  end

  def test_local_openai_compatible_endpoint_does_not_add_credentials
    body = JSON.generate(choices: [{message: {content: "ok"}, finish_reason: "stop"}])
    with_server(->(_) { ["200 OK", {"Content-Type" => "application/json"}, body] }) do |server|
      provider = Nunki::Provider.build(:local, endpoint: server.url, model: "local")
      response = provider.complete([nunki_message(:user, "hello")])
      request = server.requests.pop

      refute request[:headers].key?("authorization")
      assert_equal "ok", response.message.content.first.text
    end
  end

  def test_anthropic_streams_text_and_tool_input
    chunks = [
      {type: "message_start", message: {usage: {input_tokens: 8}}},
      {type: "content_block_start", index: 0, content_block: {type: "text", text: ""}},
      {type: "content_block_delta", index: 0, delta: {type: "text_delta", text: "hello"}},
      {type: "content_block_stop", index: 0},
      {type: "content_block_start", index: 1, content_block: {type: "tool_use", id: "tool-1", name: "weather", input: {}}},
      {type: "content_block_delta", index: 1, delta: {type: "input_json_delta", partial_json: '{"city":"Paris"}'}},
      {type: "content_block_stop", index: 1},
      {type: "message_delta", delta: {stop_reason: "tool_use"}, usage: {output_tokens: 4}},
      {type: "message_stop"}
    ]
    with_server(->(_) { ["200 OK", {"Content-Type" => "text/event-stream"}, sse(*chunks)] }) do |server|
      provider = Nunki::Provider.build(:anthropic, endpoint: server.url, api_key: "secret", model: "model")
      response = provider.complete([nunki_message(:user, "weather")], tools: [weather_tool])
      request = server.requests.pop

      assert_equal "secret", request[:headers]["x-api-key"]
      assert_equal "2023-06-01", request[:headers]["anthropic-version"]
      assert_equal "hello", response.message.content[0].text
      assert_equal({"city" => "Paris"}, response.message.content[1].tool_input)
      assert_equal [8, 4], [response.usage.input_tokens, response.usage.output_tokens]
    end
  end

  def test_validates_context_budget_and_unknown_provider
    assert_raises(Nunki::ProtocolError) do
      Nunki::Provider.build(:unknown, endpoint: "https://example.test", model: "model")
    end

    provider = Nunki::Provider.build(:local, endpoint: "https://example.test", model: "model", context_limit: 10)
    assert_raises(Nunki::ProtocolError) { provider.complete([nunki_message(:user, "hello")], max_tokens: 10) }
  end

  private

  def weather_tool
    Nunki::Tool.new(
      name: "weather",
      description: "Get weather",
      input_schema: {"type" => "object", "properties" => {"city" => {"type" => "string"}}}
    )
  end
end
