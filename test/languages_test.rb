# frozen_string_literal: true

require "test_helper"

class LanguagesTest < Minitest::Test
  def name_for(label) = NotionPublish::Languages.notion_name(label)

  def test_a_notion_name_is_kept
    assert_equal "ruby", name_for("ruby")
    assert_equal "c++", name_for("c++")
  end

  def test_case_does_not_matter
    assert_equal "sql", name_for("SQL")
  end

  def test_a_short_name_maps_to_notions
    assert_equal "yaml", name_for("yml")
    assert_equal "shell", name_for("console")
  end

  # Notion's Markdown parser would show these as JavaScript, and the block API
  # would refuse them.
  def test_an_unknown_label_is_plain_text
    assert_equal "plain text", name_for("tiles")
  end

  def test_no_label_is_plain_text
    assert_equal "plain text", name_for(nil)
  end
end
