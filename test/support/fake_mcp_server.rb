# frozen_string_literal: true

require "json"

$stdout.sync = true

def result(id, value)
  puts JSON.generate(jsonrpc: "2.0", id: id, result: value)
end

while (line = gets)
  message = JSON.parse(line)
  id = message["id"]
  case message["method"]
  when "initialize"
    result(id, {
      protocolVersion: "2025-11-25",
      capabilities: {tools: {}, resources: {}, prompts: {}},
      serverInfo: {name: "fake", version: "1"}
    })
  when "notifications/initialized", "notifications/cancelled"
    nil
  when "tools/list"
    sleep Float(ENV["NUNKI_FAKE_DELAY"]) if ENV["NUNKI_FAKE_DELAY"]
    if message.dig("params", "cursor")
      result(id, {tools: [{name: "echo2", description: "Echo again", inputSchema: {type: "object"}}]})
    else
      result(id, {tools: [{name: "echo", description: "Echo", inputSchema: {type: "object"}}], nextCursor: "2"})
    end
  when "tools/call"
    result(id, {content: [{type: "text", text: message.dig("params", "arguments", "text")}], isError: false})
  when "resources/list"
    result(id, {resources: [{uri: "memory://readme", name: "README"}]})
  when "resources/read"
    result(id, {contents: [{uri: message.dig("params", "uri"), text: "hello"}]})
  when "prompts/list"
    result(id, {prompts: [{name: "review", description: "Review code"}]})
  when "prompts/get"
    result(id, {description: "Review", messages: [{role: "user", content: {type: "text", text: "review it"}}]})
  else
    puts JSON.generate(jsonrpc: "2.0", id: id, error: {code: -32_601, message: "Method not found"})
  end
end
