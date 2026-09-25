# frozen_string_literal: true

require "test_helper"

class DocumentTest < Minitest::Test
  def test_front_matter_is_split_from_the_body
    doc = NotionPublish::Document.new("a.md", "---\ntitle: Hello\n---\n# Heading\n")

    assert_equal "Hello", doc.title
    assert_equal "# Heading\n", doc.body
  end

  def test_front_matter_may_end_the_file
    doc = NotionPublish::Document.new("a.md", "---\ntitle: Only front matter\n---")

    assert_equal "Only front matter", doc.title
    assert_equal "", doc.body
  end

  def test_windows_line_endings_are_accepted
    doc = NotionPublish::Document.new("a.md", "---\r\nnotion_parent: abc\r\n---\r\nBody\r\n")

    assert_equal "abc", doc.parent
  end

  def test_the_title_falls_back_to_the_first_heading_then_the_filename
    assert_equal "Heading", NotionPublish::Document.new("a.md", "Intro\n\n# Heading\n").title
    assert_equal "access-control", NotionPublish::Document.new("docs/access-control.md", "No heading.\n").title
  end

  def test_dates_in_front_matter_are_allowed
    doc = NotionPublish::Document.new("a.md", "---\nproperties:\n  Due: 2026-09-15\n---\n")

    assert_equal Date.new(2026, 9, 15), doc.properties["Due"]
  end

  def test_front_matter_that_is_not_a_mapping_is_refused
    error = assert_raises(NotionPublish::Error) { NotionPublish::Document.new("a.md", "---\n- a\n---\n") }

    assert_includes error.message, "must be a YAML mapping"
  end

  def test_with_body_keeps_everything_else
    doc = NotionPublish::Document.new("a.md", "---\ntitle: T\n---\nold\n")
    copy = doc.with_body("new\n")

    assert_equal "new\n", copy.body
    assert_equal "old\n", doc.body
    assert_equal "T", copy.title
    assert_equal "a.md", copy.path
  end
end
