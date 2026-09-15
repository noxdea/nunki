# frozen_string_literal: true

require "test_helper"

class SSETest < Minitest::Test
  def test_parses_split_multiline_events
    parser = Nunki::SSE::Parser.new

    assert_empty parser.feed("event: message\r\ndata: one")
    event = parser.feed("\ndata: two\r\nid: 7\r\nretry: 25\r\n\r\n").fetch(0)

    assert_equal "message", event.event
    assert_equal "one\ntwo", event.data
    assert_equal "7", event.id
    assert_equal 25, event.retry
  end

  def test_limits_event_size
    parser = Nunki::SSE::Parser.new(max_event_bytes: 4)

    assert_raises(Nunki::ProtocolError) { parser.feed("data: too large") }
  end
end
