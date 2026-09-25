# frozen_string_literal: true

require "test_helper"

class NotionDigestTest < Minitest::Test
  BASE = "https://prod-files-secure.s3.us-west-2.amazonaws.com/ws/file-id/diagram.jpg"

  def signed(date, signature)
    "#{BASE}?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Date=#{date}&X-Amz-Signature=#{signature}&x-id=GetObject"
  end

  # The same page read twice, a few seconds apart.
  def test_a_fresh_signature_does_not_change_the_hash
    first = "Intro.\n\n![Diagram](#{signed('20260925T130000Z', 'aaa')})\n"
    second = "Intro.\n\n![Diagram](#{signed('20260925T130003Z', 'bbb')})\n"

    assert_equal NotionPublish::NotionDigest.of(first), NotionPublish::NotionDigest.of(second)
  end

  def test_a_different_file_still_changes_the_hash
    first = "![Diagram](#{signed('20260925T130000Z', 'aaa')})\n"
    second = "![Diagram](#{signed('20260925T130000Z', 'aaa').sub('diagram.jpg', 'other.jpg')})\n"

    refute_equal NotionPublish::NotionDigest.of(first), NotionPublish::NotionDigest.of(second)
  end

  # Existing hashes in notion-publish-manifest.yml were taken over the raw Markdown.
  def test_a_page_without_signed_urls_hashes_as_before
    markdown = "Plain [link](https://example.com/page?a=1) and text.\n"

    assert_equal Digest::SHA256.hexdigest(markdown), NotionPublish::NotionDigest.of(markdown)
  end
end
