# frozen_string_literal: true

require "test_helper"

# Code Notion's Markdown parser cannot hold goes in as a sentinel and is
# replaced by a code block built through the block API, as images are.
class PublisherCodeTest < Minitest::Test
  PAGE = "3ceab123-cd45-8114-bcf0-e2aad8e697a7"
  SENTINEL = "NOTIONPUBLISHCODE0000"
  MARKER_BLOCK = "block-marker"
  NESTED = "````markdown\n```ruby\nputs 1\n```\n````\n"

  def setup
    stub_me
    stub_request(:post, "#{StubbingHelpers::API}/v1/pages")
      .to_return(status: 200, body: JSON.generate("object" => "page", "id" => PAGE, "url" => "https://n/p/x"))
    stub_request(:get, %r{/v1/blocks/#{PAGE}/children}).to_return(status: 200, body: JSON.generate(
      "results" => [{ "id" => MARKER_BLOCK, "type" => "paragraph",
                      "paragraph" => { "rich_text" => [{ "plain_text" => SENTINEL }] } }]
    ))
    @insert = stub_request(:patch, "#{StubbingHelpers::API}/v1/blocks/#{PAGE}/children")
              .to_return(status: 200, body: JSON.generate("results" => [{ "id" => "code" }]))
    @delete = stub_request(:delete, "#{StubbingHelpers::API}/v1/blocks/#{MARKER_BLOCK}")
              .to_return(status: 200, body: JSON.generate("object" => "block", "id" => MARKER_BLOCK))
  end

  def test_the_markdown_sent_carries_a_sentinel_not_the_code
    publish("Before.\n\n#{NESTED}")

    assert_requested(:post, "#{StubbingHelpers::API}/v1/pages") do |req|
      md = JSON.parse(req.body)["markdown"]
      md.include?(SENTINEL) && !md.include?("puts 1")
    end
  end

  def test_the_code_block_is_inserted_after_the_sentinel_and_the_sentinel_deleted
    publish(NESTED)

    assert_requested(:patch, "#{StubbingHelpers::API}/v1/blocks/#{PAGE}/children") do |req|
      body = JSON.parse(req.body)
      body.dig("position", "after_block", "id") == MARKER_BLOCK &&
        body.dig("children", 0, "code", "language") == "markdown" &&
        body.dig("children", 0, "code", "rich_text", 0, "text", "content") == "```ruby\nputs 1\n```"
    end
    assert_requested @delete
  end

  # Nothing is uploaded for code, so --no-upload does not stop it.
  def test_code_is_placed_without_uploads
    publish(NESTED, upload: false)

    assert_requested @insert
  end

  def test_an_image_shown_inside_the_code_is_not_uploaded
    publish("````markdown\n```\n![a](diagram.png)\n```\n````\n")

    assert_not_requested :post, "#{StubbingHelpers::API}/v1/file_uploads"
  end

  def test_ordinary_code_takes_the_plain_path
    publish("```ruby\nputs 1\n```\n")

    assert_not_requested @insert
  end

  def test_a_missing_sentinel_is_reported
    stub_request(:get, %r{/v1/blocks/#{PAGE}/children}).to_return(status: 200, body: JSON.generate("results" => []))
    warnings = []
    publish(NESTED, warnings: warnings)

    assert_includes warnings.join, "Could not place a code block"
  end

  private

  def target
    NotionPublish::Target.new(kind: :page, id: "parent", title: "P", database_id: nil, inline: false)
  end

  def publish(body, upload: true, warnings: [])
    Dir.mktmpdir do |dir|
      path = File.join(dir, "doc.md")
      File.write(path, body)
      NotionPublish::Publisher.new(client).publish(
        NotionPublish::Document.load(path), target: target, warnings: warnings, upload: upload
      )
    end
  end
end
