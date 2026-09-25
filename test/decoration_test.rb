# frozen_string_literal: true

require "test_helper"

# Icon and cover are top-level page fields rather than properties. An icon may
# be an emoji, a URL, or a local file; a cover has no emoji form.
class DecorationTest < Minitest::Test
  def test_an_emoji_icon
    assert_equal({ "type" => "emoji", "emoji" => "🔒" },
                 NotionPublish::Decoration.icon("🔒", client: nil))
  end

  def test_a_multi_codepoint_emoji_still_counts
    assert_equal "🇺🇸", NotionPublish::Decoration.icon("🇺🇸", client: nil)["emoji"]
  end

  def test_a_url_icon_is_external
    icon = NotionPublish::Decoration.icon("https://example.com/logo.png", client: nil)

    assert_equal "external", icon["type"]
    assert_equal "https://example.com/logo.png", icon.dig("external", "url")
  end

  def test_a_stock_notion_cover_is_just_a_url
    cover = NotionPublish::Decoration.cover(
      "https://app.notion.com/images/page-cover/artemis_ii_4.jpg", client: nil
    )

    assert_equal "external", cover["type"]
  end

  # A bare word is neither an emoji nor a path, and Notion's own error for it is
  # not obvious.
  def test_a_word_is_refused_as_an_icon
    error = assert_raises(NotionPublish::Error) { NotionPublish::Decoration.icon("padlock", client: nil) }

    assert_includes error.message, "not an emoji, a URL, or a path"
  end

  # A filename written without a path is not recognised as one, so it should be
  # refused with advice rather than sent to Notion as an emoji.
  def test_a_bare_filename_is_refused_as_an_icon
    error = assert_raises(NotionPublish::Error) { NotionPublish::Decoration.icon("logo.png", client: nil) }

    assert_includes error.message, "--icon ./logo.png"
  end

  def test_a_missing_icon_file_is_reported
    error = assert_raises(NotionPublish::Error) { NotionPublish::Decoration.icon("./nope.png", client: nil) }

    assert_includes error.message, "No such icon file"
  end

  def test_a_missing_cover_file_is_reported
    error = assert_raises(NotionPublish::Error) { NotionPublish::Decoration.cover("art.png", client: nil) }

    assert_includes error.message, "No such cover file"
  end

  def test_blank_values_produce_nothing
    assert_nil NotionPublish::Decoration.icon("  ", client: nil)
    assert_nil NotionPublish::Decoration.cover(nil, client: nil)
  end

  def test_a_local_file_is_uploaded_and_referenced_by_id
    stub_me
    stub_notion(:post, "/v1/file_uploads", status: 200, body: {
                  "id" => "up-1", "upload_url" => "#{StubbingHelpers::API}/v1/file_uploads/up-1/send"
                })
    stub_request(:post, %r{/send}).to_return(status: 200, body: JSON.generate("status" => "uploaded"))

    Dir.mktmpdir do |dir|
      path = File.join(dir, "logo.png")
      File.binwrite(path, "\x89PNG\r\n\x1a\n")

      icon = NotionPublish::Decoration.icon(path, client: client)

      assert_equal({ "type" => "file_upload", "file_upload" => { "id" => "up-1" } }, icon)
    end
  end
end
