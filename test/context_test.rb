# frozen_string_literal: true

require "test_helper"

class ContextTest < Minitest::Test
  def test_estimates_and_truncates_oldest_messages
    messages = [nunki_message(:user, "a" * 20), nunki_message(:assistant, "b" * 20), nunki_message(:user, "latest")]

    assert_operator Nunki.estimate_tokens(messages), :>, 10
    assert_equal [messages.last], Nunki.truncate(messages, max_tokens: 4)
  end

  def test_rejects_an_invalid_part
    invalid = Nunki::Part.new(type: :tool_use, text: nil, tool_name: "run", tool_input: [], tool_use_id: "1")

    assert_raises(Nunki::ProtocolError) do
      Nunki.truncate([Nunki::Message.new(role: :assistant, content: [invalid])], max_tokens: 20)
    end
  end
end
