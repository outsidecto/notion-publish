# frozen_string_literal: true

require_relative "errors"

module NotionPublish
  # Puts a local file into Notion's own storage and returns its file_upload id.
  #
  # This is the only way to get a local image onto a page: an uploaded file has
  # no URL of its own -- GET /v1/file_uploads/:id returns no url field at all --
  # so it can only ever be referenced by id from a block.
  class Uploader
    SINGLE_PART_LIMIT = 20 * 1024 * 1024

    CONTENT_TYPES = {
      ".png" => "image/png", ".jpg" => "image/jpeg", ".jpeg" => "image/jpeg",
      ".gif" => "image/gif", ".webp" => "image/webp", ".svg" => "image/svg+xml",
      ".heic" => "image/heic", ".tif" => "image/tiff", ".tiff" => "image/tiff",
      ".ico" => "image/vnd.microsoft.icon", ".bmp" => "image/bmp"
    }.freeze

    def initialize(client)
      @client = client
    end

    def upload(path)
      raise Error, "No such image: #{path}" unless File.file?(path)

      size = File.size(path)
      check_size(path, size)
      content_type = content_type_for(path)

      created = @client.post("/v1/file_uploads", {
                               "mode" => "single_part",
                               "filename" => File.basename(path),
                               "content_type" => content_type
                             })

      sent = @client.post_file(created["upload_url"], path: path, content_type: content_type)
      raise Error, "Upload of #{path} finished as #{sent['status'].inspect}." unless sent["status"] == "uploaded"

      created["id"]
    end

    # The block that references an upload. Notion reports it back as an image of
    # type "file" with a short-lived signed URL, minted fresh on every read.
    def self.image_block(upload_id, caption)
      image = { "type" => "file_upload", "file_upload" => { "id" => upload_id } }
      image["caption"] = [{ "type" => "text", "text" => { "content" => caption.to_s } }] unless caption.to_s.empty?
      { "object" => "block", "type" => "image", "image" => image }
    end

    private

    def check_size(path, size)
      limit = [workspace_limit, SINGLE_PART_LIMIT].compact.min
      return if size <= limit

      raise Error, <<~MSG.strip
        #{File.basename(path)} is #{human(size)}, over the #{human(limit)} limit.

        Files above #{human(SINGLE_PART_LIMIT)} need Notion's multi-part upload,
        which notion-publish does not do yet.
      MSG
    end

    def workspace_limit
      @client.me.dig("bot", "workspace_limits", "max_file_upload_size_in_bytes")
    end

    def content_type_for(path)
      extension = File.extname(path).downcase
      CONTENT_TYPES[extension] or raise Error, <<~MSG.strip
        Cannot tell what kind of image #{File.basename(path)} is.

        Known extensions: #{CONTENT_TYPES.keys.join(' ')}
      MSG
    end

    def human(bytes)
      return "#{(bytes / 1024.0 / 1024).round(1)} MB" if bytes >= 1024 * 1024

      "#{(bytes / 1024.0).round(1)} KB"
    end
  end
end
