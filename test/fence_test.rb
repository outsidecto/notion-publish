# frozen_string_literal: true

require "test_helper"

class FenceTest < Minitest::Test
  def steps(body)
    fence = NotionPublish::Fence.new
    body.lines.map { |line| fence.step(line) }
  end

  def test_a_fence_opens_and_closes
    assert_equal [nil, :open, :code, :close, nil], steps("a\n```\nx\n```\nb\n")
  end

  def test_a_shorter_run_does_not_close_a_longer_fence
    assert_equal %i[open code code close], steps("````\n```\nx\n````\n")
  end

  def test_the_other_character_does_not_close_a_fence
    assert_equal %i[open code close], steps("~~~\n```\n~~~\n")
  end

  def test_a_closing_line_with_a_label_is_code
    assert_equal %i[open code close], steps("```\n```ruby\n```\n")
  end

  def test_a_longer_closing_run_closes
    assert_equal %i[open close], steps("```\n`````\n")
  end

  def test_the_language_is_the_first_word_of_the_label
    fence = NotionPublish::Fence.new
    fence.step("```ruby title=\"x.rb\"\n")

    assert_equal "ruby", fence.opening.language
  end

  def test_backticks_in_the_label_mean_inline_code_not_a_fence
    assert_equal [nil, nil], steps("```a`b```\ntext\n")
  end
end
