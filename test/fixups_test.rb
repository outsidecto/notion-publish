# frozen_string_literal: true

require "test_helper"

# Notion does not honour CommonMark soft line breaks: it makes a block per line.
# A document wrapped at a column width therefore arrives double-spaced, and
# wrapped list items break out of their list.
class FixupsTest < Minitest::Test
  def join(body) = NotionPublish::Fixups.apply(body)

  def test_a_wrapped_paragraph_becomes_one_line
    assert_equal "One two three four.\n", join("One two\nthree four.\n")
  end

  # The wrapping is how the file is stored, not something the author meant to be
  # seen, so the join is a space rather than a forced line break.
  def test_wrapped_lines_join_with_a_space_not_a_break
    refute_includes join("One two\nthree.\n"), "<br>"
  end

  def test_paragraphs_separated_by_a_blank_line_stay_separate
    assert_equal "One.\n\nTwo.\n", join("One.\n\nTwo.\n")
  end

  def test_a_wrapped_list_item_stays_one_item
    assert_equal "- Technical access must be documented including the role or approver.\n",
                 join("- Technical access must be documented including the role\n  or approver.\n")
  end

  def test_list_items_stay_separate
    assert_equal "- One a\n- Two b\n", join("- One\n  a\n- Two\n  b\n")
  end

  def test_nested_list_indentation_is_kept
    assert_equal "- Top level\n  - Nested item text\n",
                 join("- Top level\n  - Nested item\n    text\n")
  end

  def test_numbered_items_are_handled_too
    assert_equal "1. First item wrapped\n", join("1. First item\n   wrapped\n")
  end

  def test_a_wrapped_blockquote_becomes_one_quote
    assert_equal "> A quotation that wraps over three lines.\n",
                 join("> A quotation\n> that wraps\n> over three lines.\n")
  end

  # A bare ">" separates paragraphs inside a quote.
  def test_a_blank_quote_line_separates_two_quotes
    assert_equal "> First para.\n>\n> Second para.\n", join("> First para.\n>\n> Second para.\n")
  end

  def test_headings_end_a_run
    assert_equal "Text here.\n## Heading\nMore text.\n", join("Text here.\n## Heading\nMore\ntext.\n")
  end

  def test_table_rows_are_never_joined
    body = "| A | B |\n| - | - |\n| 1 | 2 |\n"

    assert_equal body, join(body)
  end

  def test_thematic_breaks_end_a_run
    assert_equal "Text.\n---\nMore.\n", join("Text.\n---\nMore.\n")
  end

  def test_fenced_code_is_left_exactly_alone
    body = "```ruby\ndef a\n  b\nend\n```\n"

    assert_equal body, join(body)
  end

  def test_text_after_a_fence_still_joins
    assert_equal "```\nx\n```\nOne two.\n", join("```\nx\n```\nOne\ntwo.\n")
  end

  # An explicit hard break is the one case the author did mean to be seen.
  def test_two_trailing_spaces_become_a_line_break
    assert_equal "One<br>two.\n", join("One  \ntwo.\n")
  end

  def test_a_trailing_backslash_becomes_a_line_break
    assert_equal "One<br>two.\n", join("One\\\ntwo.\n")
  end

  def test_html_blocks_end_a_run
    assert_equal "Text.\n<callout>\n", join("Text.\n<callout>\n")
  end

  def test_a_document_with_nothing_to_fix_is_unchanged
    body = "# Title\n\nA single line.\n\n- One item\n"

    assert_equal body, join(body)
  end

  # Notion consumes a leading H1 as the page title only when it is the sole H1
  # in the document. A "# Revision History" at the foot is enough to make it
  # keep both, and the title then shows up twice.
  def test_a_leading_h1_is_removed
    assert_equal "Body text.\n", NotionPublish::Fixups.strip_leading_h1("# Title\n\nBody text.\n")
  end

  def test_later_h1s_are_kept
    body = "# Title\n\nText.\n\n# Revision History\n"

    assert_equal "Text.\n\n# Revision History\n", NotionPublish::Fixups.strip_leading_h1(body)
  end

  def test_a_document_not_starting_with_h1_is_untouched
    body = "Intro.\n\n# Not First\n"

    assert_equal body, NotionPublish::Fixups.strip_leading_h1(body)
  end

  def test_an_h2_is_not_mistaken_for_the_title
    body = "## Subheading\n\nText.\n"

    assert_equal body, NotionPublish::Fixups.strip_leading_h1(body)
  end

  def test_leading_blank_lines_before_the_h1_are_handled
    assert_equal "Text.\n", NotionPublish::Fixups.strip_leading_h1("\n\n# Title\n\nText.\n")
  end

  def test_trailing_newline_is_not_required
    assert_equal "One two.\n", join("One\ntwo.")
  end
end
