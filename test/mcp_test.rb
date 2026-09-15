# frozen_string_literal: true

require "test_helper"
require "rbconfig"

class MCPTest < Minitest::Test
  def test_stdio_tools_resources_and_prompts
    command = [RbConfig.ruby, File.expand_path("support/fake_mcp_server.rb", __dir__)]
    client = Nunki::MCP::Client.stdio(command: command, timeout: 2)

    initialized = client.start
    assert_equal "fake", initialized.dig("serverInfo", "name")
    assert_equal %w[echo echo2], client.tools.map { |tool| tool["name"] }
    assert_equal "hello", client.call_tool("echo", {"text" => "hello"}).dig("content", 0, "text")
    assert_equal "memory://readme", client.resources.first["uri"]
    assert_equal "hello", client.read_resource("memory://readme").dig("contents", 0, "text")
    assert_equal "review", client.prompts.first["name"]
    assert_equal "review it", client.get_prompt("review").dig("messages", 0, "content", "text")
  ensure
    client&.close
  end

  def test_streamable_http_tools_resources_and_prompts
    seen = Queue.new
    handler = lambda do |request|
      message = request[:body].empty? ? {} : JSON.parse(request[:body])
      seen << request
      return ["204 No Content", {}, ""] if request[:method] == "DELETE"
      return ["202 Accepted", {}, ""] unless message["id"]

      result = mcp_result(message)
      headers = {"Content-Type" => "application/json"}
      headers["MCP-Session-Id"] = "session-1" if message["method"] == "initialize"
      ["200 OK", headers, JSON.generate(jsonrpc: "2.0", id: message["id"], result: result)]
    end

    with_server(handler) do |server|
      client = Nunki::MCP::Client.http(url: server.url, timeout: 2, retries: 0)
      client.start
      assert_equal "echo", client.tools.first["name"]
      assert_equal "ok", client.call_tool("echo", {}).dig("content", 0, "text")
      assert_equal "memory://readme", client.resources.first["uri"]
      assert_equal "resource", client.read_resource("memory://readme").dig("contents", 0, "text")
      assert_equal "review", client.prompts.first["name"]
      assert_equal "prompt", client.get_prompt("review").dig("messages", 0, "content", "text")
      client.close

      requests = []
      requests << seen.pop until seen.empty?
      initialized = requests.find { |request| JSON.parse(request[:body]).fetch("method", nil) == "notifications/initialized" }
      assert_equal "session-1", initialized[:headers]["mcp-session-id"]
      assert_equal Nunki::MCP::PROTOCOL_VERSION, initialized[:headers]["mcp-protocol-version"]
      assert requests.any? { |request| request[:method] == "DELETE" }
    ensure
      client&.close
    end
  end

  def test_rejects_operation_before_start
    command = [RbConfig.ruby, File.expand_path("support/fake_mcp_server.rb", __dir__)]
    client = Nunki::MCP::Client.stdio(command: command)

    assert_raises(Nunki::Error) { client.tools }
  ensure
    client&.close
  end

  def test_stdio_request_timeout_and_cleanup
    command = [RbConfig.ruby, File.expand_path("support/fake_mcp_server.rb", __dir__)]
    client = Nunki::MCP::Client.stdio(command: command, env: {"NUNKI_FAKE_DELAY" => "2"}, timeout: 0.5)
    client.start

    assert_raises(Nunki::Timeout) { client.tools }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    client.close
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1.5
  ensure
    client&.close
  end

  private

  def mcp_result(message)
    case message["method"]
    when "initialize"
      {protocolVersion: Nunki::MCP::PROTOCOL_VERSION, capabilities: {tools: {}, resources: {}, prompts: {}}, serverInfo: {name: "fake", version: "1"}}
    when "tools/list" then {tools: [{name: "echo", inputSchema: {type: "object"}}]}
    when "tools/call" then {content: [{type: "text", text: "ok"}]}
    when "resources/list" then {resources: [{uri: "memory://readme", name: "README"}]}
    when "resources/read" then {contents: [{uri: "memory://readme", text: "resource"}]}
    when "prompts/list" then {prompts: [{name: "review"}]}
    when "prompts/get" then {messages: [{role: "user", content: {type: "text", text: "prompt"}}]}
    else {}
    end
  end
end
