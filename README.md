# Nunki

Nunki is a pure Ruby, provider-neutral client for streaming LLM APIs and the
Model Context Protocol (MCP). It supplies protocol and transport behavior while
leaving prompts, UI, context selection, and edits to the host application.

## Installation

```bash
bundle add nunki
```

## LLM providers

The endpoint is always explicit. Pass the full completion/messages URL supplied
by your service configuration.

```ruby
require "nunki"

provider = Nunki::Provider.build(
  :openai,
  endpoint: ENV.fetch("LLM_ENDPOINT"),
  api_key: ENV.fetch("LLM_API_KEY"),
  model: "configured-model"
)

text = Nunki::Part.new(
  type: :text, text: "Explain this method",
  tool_name: nil, tool_input: nil, tool_use_id: nil
)
message = Nunki::Message.new(role: :user, content: [text])

response = provider.complete([message]) do |part|
  print part.text if part.type == :text
end
```

Supported kinds are `:openai`, `:openai_compatible`, `:local`, and
`:anthropic`. The OpenAI-compatible local kind does not add an authorization
header unless an API key is supplied. A completion returns `Nunki::Response`;
tool requests appear as `:tool_use` parts containing `tool_name`, `tool_input`,
and `tool_use_id`. Send results back as `:tool_result` parts.

`provider.cancel` interrupts streaming or a retry wait. HTTP 429 and 5xx
responses are retried with exponential backoff. `dispatch:` may move blocking
work onto an application-owned worker:

```ruby
provider = Nunki::Provider.build(
  :local,
  endpoint: settings.fetch("endpoint"),
  model: settings.fetch("model"),
  dispatch: ->(&work) { Thread.new(&work) }
)
```

`Nunki.estimate_tokens(value)` provides a byte-based estimate.
`Nunki.truncate(messages, max_tokens:)` drops the oldest messages while always
retaining the newest one, or raises if that message alone exceeds the budget.

## MCP

Nunki implements MCP 2025-11-25 over newline-delimited stdio and Streamable
HTTP. Both transports support tools, resources, prompts, pagination, request
timeouts, and protocol errors.

```ruby
client = Nunki::MCP::Client.stdio(command: ["my-mcp-server"])
# Or: Nunki::MCP::Client.http(url: settings.fetch("mcp_url"), headers: {...})

client.start
client.tools
client.call_tool("lookup", {"query" => "Ruby"})
client.resources
client.read_resource("file:///project/README.md")
client.prompts
client.get_prompt("review", {"language" => "ruby"})
client.close
```

`close` closes a stdio server's input, waits briefly, then uses TERM and KILL if
needed. HTTP sessions are ended with DELETE when the server issued a session ID.

## Limits and security

Default limits are 1 MiB per HTTP request, 8 MiB per HTTP response/SSE event,
and 4 MiB per stdio MCP message. Provider HTTP defaults are a 10-second connect
timeout and 60-second read timeout; MCP requests default to 30 seconds. All are
configurable at construction.

Nunki deliberately accepts local and remote HTTP(S) endpoints because every
endpoint is configuration-derived. This means an untrusted endpoint setting is
an SSRF capability: hosts must validate it against their own trust policy.
Nunki has no default endpoints and never persists credentials; supplied keys
exist only in the client instance and request headers.

Nunki does not choose prompts or context, render UI, save credentials, execute
tool requests without a caller decision, or apply model-produced diffs.

## Development

```bash
bundle install
bundle exec rake test
bundle exec rbs -I sig validate
BUDGET=1 bundle exec rake bench
gem build --strict nunki.gemspec
```

## Contributing

Bug reports and pull requests are welcome at https://github.com/noxdea/nunki.

## License

The gem is available under the [MIT License](LICENSE.txt).
