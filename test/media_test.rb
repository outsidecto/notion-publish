# frozen_string_literal: true

require "test_helper"

class MediaTest < Minitest::Test
  def scan(body) = NotionPublish::Media.scan(body, base_dir: "/docs")

  def test_an_external_image_is_left_alone
    media = scan("![dot](https://example.com/dot.png)\n")

    refute_predicate media, :any?
    assert_equal "![dot](https://example.com/dot.png)\n", media.body_with_sentinels
  end

  def test_a_local_image_becomes_a_sentinel
    media = scan("Before.\n\n![A diagram](./diagram.png)\n\nAfter.\n")

    assert_equal 1, media.images.length
    assert_equal "./diagram.png", media.images.first.path
    assert_equal "A diagram", media.images.first.alt
    assert_includes media.body_with_sentinels, "NOTIONPUBLISHIMAGE0000"
    refute_includes media.body_with_sentinels, "diagram.png"
  end

  def test_sentinels_are_numbered_per_image
    media = scan("![a](one.png)\n\n![b](two.png)\n")

    assert_equal %w[NOTIONPUBLISHIMAGE0000 NOTIONPUBLISHIMAGE0001], media.images.map(&:sentinel)
  end

  # The sentinel has to survive Markdown parsing as one plain paragraph, so it
  # is a bare alphanumeric run with nothing Notion could interpret.
  def test_the_sentinel_has_no_markdown_syntax_in_it
    assert_match(/\A[A-Z0-9]+\z/, scan("![a](x.png)\n").images.first.sentinel)
  end

  def test_paths_resolve_against_the_document_directory
    media = scan("![a](img/x.png)\n")

    assert_equal "/docs/img/x.png", media.resolved_path(media.images.first)
  end

  def test_images_inside_fenced_code_are_ignored
    body = "```markdown\n![a](x.png)\n```\n"
    media = scan(body)

    refute_predicate media, :any?
    assert_equal body, media.body_with_sentinels
  end

  def test_tilde_fences_are_honoured_too
    media = scan("~~~\n![a](x.png)\n~~~\n")

    refute_predicate media, :any?
  end

  # Notion has no inline image, so one inside a sentence cannot become a block.
  def test_an_inline_image_is_reported_not_rewritten
    media = scan("See ![a](x.png) here.\n")

    refute_predicate media, :any?
    assert_equal ["x.png"], media.inline_paths
    assert_includes media.body_with_sentinels, "![a](x.png)"
  end

  def test_an_inline_external_image_is_not_reported
    media = scan("See ![a](https://example.com/x.png) here.\n")

    assert_empty media.inline_paths
  end

  # A malformed URL produces the same silent empty-URL block a relative path
  # does, so it is treated as local rather than charitably passed through.
  def test_a_malformed_url_counts_as_local
    media = scan("![a](htp:/example.com/x.png)\n")

    assert_equal 1, media.images.length
  end

  def test_titles_after_the_url_are_stripped
    media = scan(%(![a](x.png "A title")\n))

    assert_equal "x.png", media.images.first.path
  end

  def test_leading_whitespace_still_counts_as_standalone
    assert_equal 1, scan("  ![a](x.png)\n").images.length
  end

  def test_percent_encoded_spaces_are_decoded
    assert_equal "my diagram.png", scan("![a](my%20diagram.png)\n").images.first.path
  end
end
