# frozen_string_literal: true

require "benchmark"
require_relative "../lib/nunki"

payload = 10_000.times.map { |index| "data: {\"index\":#{index}}\n\n" }.join
elapsed = Benchmark.realtime do
  parser = Nunki::SSE::Parser.new(max_event_bytes: payload.bytesize)
  events = parser.feed(payload)
  raise "incorrect event count" unless events.length == 10_000
end

puts format("SSE parse: %.3f ms", elapsed * 1000)
raise "SSE parsing exceeded 1 second" if ENV["BUDGET"] == "1" && elapsed > 1
