# frozen_string_literal: true

require "test_helper"

# Notion ends a code block at any line starting with three backticks, so code
# showing a fence has to be sent through the block API.
class CodeBlocksTest < Minitest::Test
  def scan(body) = NotionPublish::CodeBlocks.scan(body)

  def test_code_notion_can_parse_is_left_alone
    body = "```ruby\nputs 1\n```\n"
    code = scan(body)

    refute_predicate code, :any?
    assert_equal body, code.body
  end

  def test_code_showing_a_fence_becomes_a_sentinel
    code = scan("Before.\n\n````markdown\n```ruby\nputs 1\n```\n````\n\nAfter.\n")

    assert_equal "Before.\n\nNOTIONPUBLISHCODE0000\n\nAfter.\n", code.body
    assert_equal "```ruby\nputs 1\n```", code.blocks.first.code
    assert_equal "markdown", code.blocks.first.language
  end

  def test_backticks_inside_a_tilde_fence_become_a_sentinel
    code = scan("~~~\n```\nx\n```\n~~~\n")

    assert_equal "NOTIONPUBLISHCODE0000\n", code.body
    assert_equal "plain text", code.blocks.first.language
  end

  def test_each_block_gets_its_own_sentinel
    code = scan("````\n```\n````\n\n````\n```\n````\n")

    assert_equal %w[NOTIONPUBLISHCODE0000 NOTIONPUBLISHCODE0001], code.blocks.map(&:sentinel)
  end

  # The sentinel keeps the fence's indentation, so it lands in the same list
  # item or callout, and the code loses that indentation as CommonMark says.
  def test_an_indented_fence_keeps_its_place
    code = scan("- Item\n\n  ````\n  ```\n    nested\n  ````\n")

    assert_equal "- Item\n\n  NOTIONPUBLISHCODE0000\n", code.body
    assert_equal "```\n  nested", code.blocks.first.code
  end

  def test_an_unclosed_fence_runs_to_the_end
    code = scan("````\n```\nx\n")

    assert_equal "NOTIONPUBLISHCODE0000\n", code.body
    assert_equal "```\nx", code.blocks.first.code
  end

  def test_the_block_is_a_notion_code_block
    block = scan("````sql\n```\nSELECT 1;\n````\n").blocks.first

    assert_equal [{ "type" => "code", "code" => { "language" => "sql", "rich_text" => [
      { "type" => "text", "text" => { "content" => "```\nSELECT 1;" } }
    ] } }], block.to_notion
  end

  def test_long_code_is_cut_into_pieces_notion_accepts
    block = scan("````\n```\n#{'x' * 2500}\n````\n").blocks.first
    pieces = block.to_notion.first.dig("code", "rich_text").map { |item| item.dig("text", "content") }

    assert_equal [1000, 1000, 504], pieces.map(&:length)
    assert_equal "```\n#{'x' * 2500}", pieces.join
  end

  def test_code_past_a_hundred_pieces_becomes_more_blocks
    block = scan("````\n```\n#{'x' * 150_000}\n````\n").blocks.first

    assert_equal 2, block.to_notion.length
  end
end
