# frozen_string_literal: true

require "test_helper"

class ReferenceTest < Minitest::Test
  UUID = "32dab123-cd45-803f-94c2-d29516bd0188"
  HEX = "32dab123cd45803f94c2d29516bd0188"

  def test_accepts_bare_hex
    assert_equal UUID, NotionPublish::Reference.parse(HEX).uuid
  end

  def test_accepts_dashed_uuid
    assert_equal UUID, NotionPublish::Reference.parse(UUID).uuid
  end

  def test_accepts_uppercase
    assert_equal UUID, NotionPublish::Reference.parse(HEX.upcase).uuid
  end

  def test_accepts_app_notion_url_with_p_segment
    ref = NotionPublish::Reference.parse("https://app.notion.com/p/Security-and-Compliance-S-C-#{HEX}")

    assert_equal UUID, ref.uuid
    assert_equal "Security and Compliance S C", ref.slug_title
  end

  def test_accepts_notion_so_url
    ref = NotionPublish::Reference.parse("https://www.notion.so/Acme-Home-2-0-#{HEX}")

    assert_equal UUID, ref.uuid
    assert_equal "Acme Home 2 0", ref.slug_title
  end

  def test_accepts_workspace_prefixed_url
    ref = NotionPublish::Reference.parse("https://www.notion.so/acme/Some-Page-#{HEX}")

    assert_equal UUID, ref.uuid
  end

  # A database URL carries the view ID in ?v=; only the path holds the object ID.
  def test_ignores_view_id_in_query_string
    view = "aaaaaaaabbbbccccddddeeeeeeeeeeee"
    ref = NotionPublish::Reference.parse("https://www.notion.so/Docs-#{HEX}?v=#{view}&pvs=4")

    assert_equal UUID, ref.uuid
  end

  def test_ignores_fragment
    assert_equal UUID, NotionPublish::Reference.parse("https://www.notion.so/Docs-#{HEX}#block").uuid
  end

  def test_url_encoded_slug_is_decoded
    ref = NotionPublish::Reference.parse("https://www.notion.so/Q3-%26-Q4-Plan-#{HEX}")

    assert_equal "Q3 & Q4 Plan", ref.slug_title
  end

  def test_no_slug_title_when_url_is_only_an_id
    assert_nil NotionPublish::Reference.parse("https://www.notion.so/#{HEX}").slug_title
  end

  def test_rejects_input_without_an_id
    assert_raises(NotionPublish::InvalidReference) { NotionPublish::Reference.parse("https://notion.so/Some-Page") }
  end

  def test_rejects_empty_input
    assert_raises(NotionPublish::InvalidReference) { NotionPublish::Reference.parse("   ") }
  end

  # Guarding both ends stops a 32-character window inside a longer hex run.
  def test_rejects_oversized_hex_run
    assert_raises(NotionPublish::InvalidReference) { NotionPublish::Reference.parse("a" * 40) }
  end
end
