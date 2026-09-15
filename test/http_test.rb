# frozen_string_literal: true

require "test_helper"

class HTTPTest < Minitest::Test
  def test_retries_server_errors
    attempts = 0
    handler = lambda do |_request|
      attempts += 1
      attempts < 3 ? ["500 Error", {}, "retry"] : ["200 OK", {"Content-Type" => "application/json"}, '{"ok":true}']
    end
    with_server(handler) do |server|
      result = Nunki::HTTP::Client.new(endpoint: server.url, retries: 2, retry_base: 0).post_json({test: true})

      assert_equal 3, attempts
      assert_equal '{"ok":true}', result.body
    end
  end

  def test_reports_rate_limit_after_retries
    with_server(->(_) { ["429 Too Many Requests", {"Retry-After" => "2"}, "slow down"] }) do |server|
      error = assert_raises(Nunki::RateLimited) do
        Nunki::HTTP::Client.new(endpoint: server.url, retries: 0).post_json({})
      end

      assert_equal 2.0, error.retry_after
    end
  end

  def test_cancel_interrupts_backoff
    with_server(->(_) { ["500 Error", {}, "retry"] }) do |server|
      client = Nunki::HTTP::Client.new(endpoint: server.url, retries: 3, retry_base: 10)
      result = Queue.new
      thread = Thread.new do
        client.post_json({})
      rescue => error
        result << error
      end
      server.requests.pop
      client.cancel

      assert thread.join(1), "cancel did not interrupt retry wait"
      assert_instance_of Nunki::Cancelled, result.pop
    end
  end

  def test_rejects_unsafe_endpoints_and_oversized_input
    assert_raises(Nunki::ProtocolError) { Nunki::HTTP::Client.new(endpoint: "file:///tmp/socket") }
    client = Nunki::HTTP::Client.new(endpoint: "http://127.0.0.1:1", max_request_bytes: 4)
    assert_raises(Nunki::ProtocolError) { client.post_json({value: "large"}) }
  end
end
