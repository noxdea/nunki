# frozen_string_literal: true

require_relative "../lib/nunki"

payload = 10_000.times.map { |index| "data: {\"index\":#{index}}\n\n" }.join
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
parser = Nunki::SSE::Parser.new(max_event_bytes: payload.bytesize)
events = parser.feed(payload)
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
raise "incorrect event count" unless events.length == 10_000

puts format("SSE parse: %.3f ms", elapsed * 1000)
raise "SSE parsing exceeded 1 second" if ENV["BUDGET"] == "1" && elapsed > 1
