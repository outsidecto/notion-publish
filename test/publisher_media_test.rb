# frozen_string_literal: true

require "test_helper"

# The hybrid path: publish through Notion's Markdown parser, then hand-build
# only the image blocks, which Markdown cannot express.
class PublisherMediaTest < Minitest::Test
  PAGE = "3ceab123-cd45-8114-bcf0-e2aad8e697a7"
  UPLOAD = "3ceab123-cd45-816b-9828-00b2e303bfca"
  SENTINEL = "NOTIONPUBLISHIMAGE0000"
  MARKER_BLOCK = "block-marker"

  def setup
    stub_me
    stub_notion(:post, "/v1/file_uploads", status: 200, body: {
                  "id" => UPLOAD, "upload_url" => "#{StubbingHelpers::API}/v1/file_uploads/#{UPLOAD}/send"
                })
    stub_request(:post, %r{/v1/file_uploads/.*/send})
      .to_return(status: 200, body: JSON.generate("status" => "uploaded"))
    stub_request(:post, "#{StubbingHelpers::API}/v1/pages")
      .to_return(status: 200, body: JSON.generate("object" => "page", "id" => PAGE, "url" => "https://n/p/x"))
    stub_request(:get, %r{/v1/blocks/#{PAGE}/children}).to_return(status: 200, body: JSON.generate(
      "results" => [
        { "id" => "block-intro", "type" => "paragraph",
          "paragraph" => { "rich_text" => [{ "plain_text" => "Before." }] } },
        { "id" => MARKER_BLOCK, "type" => "paragraph",
          "paragraph" => { "rich_text" => [{ "plain_text" => SENTINEL }] } }
      ]
    ))
    @insert = stub_request(:patch, "#{StubbingHelpers::API}/v1/blocks/#{PAGE}/children")
              .to_return(status: 200, body: JSON.generate("results" => [{ "id" => "img" }]))
    @delete = stub_request(:delete, "#{StubbingHelpers::API}/v1/blocks/#{MARKER_BLOCK}")
              .to_return(status: 200, body: JSON.generate("object" => "block", "id" => MARKER_BLOCK))
  end

  def target
    NotionPublish::Target.new(kind: :page, id: "parent", title: "P", database_id: nil, inline: false)
  end

  def test_the_markdown_sent_carries_a_sentinel_not_the_local_path
    publish("Before.\n\n![A diagram](diagram.png)\n")

    assert_requested(:post, "#{StubbingHelpers::API}/v1/pages") do |req|
      md = JSON.parse(req.body)["markdown"]
      md.include?(SENTINEL) && !md.include?("diagram.png")
    end
  end

  def test_the_image_block_is_inserted_after_the_sentinel
    publish("Before.\n\n![A diagram](diagram.png)\n")

    assert_requested(:patch, "#{StubbingHelpers::API}/v1/blocks/#{PAGE}/children") do |req|
      body = JSON.parse(req.body)
      body.dig("position", "after_block", "id") == MARKER_BLOCK &&
        body.dig("children", 0, "image", "file_upload", "id") == UPLOAD &&
        body.dig("children", 0, "image", "caption", 0, "text", "content") == "A diagram"
    end
  end

  def test_the_sentinel_is_deleted_afterwards
    publish("Before.\n\n![A diagram](diagram.png)\n")

    assert_requested @delete
  end

  def test_a_document_without_local_images_takes_the_plain_path
    publish("Just text.\n\n![x](https://example.com/x.png)\n", image: false)

    assert_not_requested :post, "#{StubbingHelpers::API}/v1/file_uploads"
    assert_not_requested @insert
    assert_requested(:post, "#{StubbingHelpers::API}/v1/pages") do |req|
      JSON.parse(req.body)["markdown"].include?("https://example.com/x.png")
    end
  end

  # Uploading first means a missing image fails before a page exists.
  def test_a_missing_image_fails_before_the_page_is_created
    assert_raises(NotionPublish::Error) { publish("![a](missing.png)\n", image: false) }

    assert_not_requested :post, "#{StubbingHelpers::API}/v1/pages"
  end

  def test_no_upload_leaves_the_body_alone_and_warns
    warnings = []
    publish("![a](diagram.png)\n", upload: false, warnings: warnings)

    assert_not_requested :post, "#{StubbingHelpers::API}/v1/file_uploads"
    assert_includes warnings.join, "Not uploading diagram.png"
    assert_requested(:post, "#{StubbingHelpers::API}/v1/pages") do |req|
      JSON.parse(req.body)["markdown"].include?("diagram.png")
    end
  end

  def test_an_inline_image_is_warned_about
    warnings = []
    publish("See ![a](diagram.png) here.\n", warnings: warnings)

    assert_includes warnings.join, "inline image"
  end

  # A long document puts the sentinel past the first page of children.
  def test_a_sentinel_on_a_later_page_of_blocks_is_found
    children = "#{StubbingHelpers::API}/v1/blocks/#{PAGE}/children"
    stub_request(:get, "#{children}?page_size=100").to_return(status: 200, body: JSON.generate(
      "results" => [{ "id" => "block-intro", "type" => "paragraph", "paragraph" => { "rich_text" => [] } }],
      "has_more" => true, "next_cursor" => "c2"
    ))
    stub_request(:get, "#{children}?page_size=100&start_cursor=c2").to_return(status: 200, body: JSON.generate(
      "results" => [{ "id" => MARKER_BLOCK, "type" => "paragraph",
                      "paragraph" => { "rich_text" => [{ "plain_text" => SENTINEL }] } }],
      "has_more" => false
    ))
    warnings = []
    publish("![a](diagram.png)\n", warnings: warnings)

    assert_empty warnings
    assert_requested @delete
  end

  # An image under a list item is published nested inside that item, so its
  # sentinel is a child of the list block rather than of the page.
  def test_a_sentinel_nested_in_a_list_item_is_found
    stub_request(:get, %r{/v1/blocks/#{PAGE}/children}).to_return(status: 200, body: JSON.generate(
      "results" => [{ "id" => "list-item", "type" => "numbered_list_item", "has_children" => true,
                      "numbered_list_item" => { "rich_text" => [{ "plain_text" => "The figure:" }] } }]
    ))
    stub_request(:patch, "#{StubbingHelpers::API}/v1/blocks/list-item/children")
      .to_return(status: 200, body: JSON.generate("results" => [{ "id" => "img" }]))
    stub_request(:get, %r{/v1/blocks/list-item/children}).to_return(status: 200, body: JSON.generate(
      "results" => [{ "id" => MARKER_BLOCK, "type" => "paragraph",
                      "paragraph" => { "rich_text" => [{ "plain_text" => SENTINEL }] } }]
    ))
    warnings = []
    publish("1. The figure:\n   ![a](diagram.png)\n", warnings: warnings)

    assert_empty warnings
    # Appended under the list item that holds the sentinel, not under the page.
    assert_requested(:patch, "#{StubbingHelpers::API}/v1/blocks/list-item/children") do |req|
      JSON.parse(req.body).dig("position", "after_block", "id") == MARKER_BLOCK
    end
    assert_not_requested(:patch, "#{StubbingHelpers::API}/v1/blocks/#{PAGE}/children")
    assert_requested @delete
  end

  # If Notion's parser swallowed the sentinel, say so rather than silently
  # publishing a document with a missing diagram.
  def test_a_missing_sentinel_is_reported
    stub_request(:get, %r{/v1/blocks/#{PAGE}/children}).to_return(status: 200, body: JSON.generate("results" => []))
    warnings = []
    publish("![a](diagram.png)\n", warnings: warnings)

    assert_includes warnings.join, "Could not place diagram.png"
  end

  private

  def publish(body, image: true, upload: true, warnings: [])
    Dir.mktmpdir do |dir|
      File.binwrite(File.join(dir, "diagram.png"), "\x89PNG\r\n\x1a\n") if image
      path = File.join(dir, "doc.md")
      File.write(path, body)
      document = NotionPublish::Document.load(path)
      NotionPublish::Publisher.new(client).publish(
        document, target: target, warnings: warnings, upload: upload
      )
    end
  end
end
