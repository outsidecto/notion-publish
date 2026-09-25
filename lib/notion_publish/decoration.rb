# frozen_string_literal: true

require_relative "errors"
require_relative "uploader"

module NotionPublish
  # Page icon and cover.
  #
  # Both are top-level fields on a page rather than properties, and both are
  # writable at creation. Notion's own stock covers are ordinary external URLs,
  # so a URL, a local file, or (for an icon) an emoji all work.
  module Decoration
    URL = %r{\Ahttps?://}i
    # Anything with a path separator, or a leading . or ~, is meant as a file.
    PATH = %r{\A[.~]|/}

    module_function

    # Validate without uploading, so a dry run can reject a bad icon or a
    # missing file without spending a round trip or leaving an orphan upload.
    def check!(value, kind)
      raw = value.to_s.strip
      return if raw.empty? || raw.match?(URL)

      if raw.match?(PATH) || kind == :cover
        expanded = File.expand_path(raw)
        raise Error, "No such #{kind} file: #{raw}" unless File.file?(expanded)

        return
      end

      raise Error, icon_message(raw) if raw.ascii_only? || raw.length > 8
    end

    def icon(value, client:)
      raw = value.to_s.strip
      return nil if raw.empty?
      return external(raw) if raw.match?(URL)
      return file_upload(raw, client, "icon") if raw.match?(PATH)

      # Emoji are never ASCII. Catching that here gives a better message than
      # Notion's for the common mistakes: a bare word, or a filename written
      # without a path so it was not recognised as one.
      raise Error, icon_message(raw) if raw.ascii_only? || raw.length > 8

      { "type" => "emoji", "emoji" => raw }
    end

    def cover(value, client:)
      raw = value.to_s.strip
      return nil if raw.empty?
      return external(raw) if raw.match?(URL)

      file_upload(raw, client, "cover")
    end

    def external(url) = { "type" => "external", "external" => { "url" => url } }

    def file_upload(path, client, what)
      expanded = File.expand_path(path)
      raise Error, "No such #{what} file: #{path}" unless File.file?(expanded)

      { "type" => "file_upload", "file_upload" => { "id" => Uploader.new(client).upload(expanded) } }
    end

    def icon_message(raw)
      <<~MSG.strip
        #{raw.inspect} is not an emoji, a URL, or a path to a file.

        An icon can be an emoji (--icon 🔒), an image URL, or a local image file
        given with a path (--icon ./logo.png).
      MSG
    end
  end
end
