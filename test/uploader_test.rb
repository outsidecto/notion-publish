# frozen_string_literal: true

require "test_helper"

class UploaderTest < Minitest::Test
  UPLOAD_ID = "3ceab123-cd45-816b-9828-00b2e303bfca"

  def test_a_file_is_created_then_sent
    stub_me
    stub_notion(:post, "/v1/file_uploads", status: 200, body: {
                  "object" => "file_upload", "id" => UPLOAD_ID, "status" => "pending",
                  "upload_url" => "https://api.notion.com/v1/file_uploads/#{UPLOAD_ID}/send"
                })
    send_stub = stub_request(:post, "#{StubbingHelpers::API}/v1/file_uploads/#{UPLOAD_ID}/send")
                .to_return(status: 200, body: JSON.generate("object" => "file_upload", "status" => "uploaded"))

    with_image("dot.png") do |path|
      assert_equal UPLOAD_ID, NotionPublish::Uploader.new(client).upload(path)
    end

    assert_requested send_stub
  end

  def test_the_send_is_multipart_with_the_right_content_type
    stub_me
    stub_notion(:post, "/v1/file_uploads", status: 200, body: {
                  "id" => UPLOAD_ID, "upload_url" => "https://api.notion.com/v1/file_uploads/#{UPLOAD_ID}/send"
                })
    stub_request(:post, %r{/send}).to_return(status: 200, body: JSON.generate("status" => "uploaded"))

    with_image("dot.png") { |path| NotionPublish::Uploader.new(client).upload(path) }

    assert_requested(:post, %r{/send}) do |req|
      req.headers["Content-Type"].start_with?("multipart/form-data; boundary=") &&
        req.body.include?('filename="dot.png"') && req.body.include?("Content-Type: image/png")
    end
  end

  def test_a_missing_file_is_reported
    error = assert_raises(NotionPublish::Error) { NotionPublish::Uploader.new(client).upload("/nope/x.png") }

    assert_includes error.message, "No such image"
  end

  def test_an_unknown_extension_is_refused
    stub_me
    with_image("notes.xyz") do |path|
      error = assert_raises(NotionPublish::Error) { NotionPublish::Uploader.new(client).upload(path) }

      assert_includes error.message, "Cannot tell what kind of image"
      assert_includes error.message, ".png"
    end
  end

  # The workspace's own ceiling comes back on /v1/users/me, so it can be
  # checked before spending a round trip on the upload.
  def test_the_workspace_limit_is_honoured
    stub_request(:get, "#{StubbingHelpers::API}/v1/users/me").to_return(status: 200, body: JSON.generate(
      "object" => "user", "id" => "u", "name" => "Bot", "type" => "bot",
      "bot" => { "owner" => { "type" => "workspace" }, "workspace_limits" => { "max_file_upload_size_in_bytes" => 16 } }
    ))

    with_image("dot.png", bytes: "x" * 64) do |path|
      error = assert_raises(NotionPublish::Error) { NotionPublish::Uploader.new(client).upload(path) }

      assert_includes error.message, "over the"
    end
  end

  def test_a_failed_send_is_not_treated_as_success
    stub_me
    stub_notion(:post, "/v1/file_uploads", status: 200, body: {
                  "id" => UPLOAD_ID, "upload_url" => "https://api.notion.com/v1/file_uploads/#{UPLOAD_ID}/send"
                })
    stub_request(:post, %r{/send}).to_return(status: 200, body: JSON.generate("status" => "pending"))

    with_image("dot.png") do |path|
      error = assert_raises(NotionPublish::Error) { NotionPublish::Uploader.new(client).upload(path) }

      assert_includes error.message, "finished as \"pending\""
    end
  end

  def test_the_image_block_references_the_upload_by_id
    block = NotionPublish::Uploader.image_block(UPLOAD_ID, "A diagram")

    assert_equal "image", block["type"]
    assert_equal({ "id" => UPLOAD_ID }, block.dig("image", "file_upload"))
    assert_equal "A diagram", block.dig("image", "caption", 0, "text", "content")
  end

  def test_an_empty_alt_produces_no_caption
    refute NotionPublish::Uploader.image_block(UPLOAD_ID, "").key?("caption")
  end

  private

  def with_image(name, bytes: "\x89PNG\r\n\x1a\n")
    Dir.mktmpdir do |dir|
      path = File.join(dir, name)
      File.binwrite(path, bytes)
      yield path
    end
  end
end
