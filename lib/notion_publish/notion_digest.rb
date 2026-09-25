# frozen_string_literal: true

require "digest"

module NotionPublish
  # The hash of a page as Notion returns it, used to notice edits made in
  # Notion.
  #
  # An uploaded file comes back as a signed S3 URL whose query string is
  # minted fresh on every read, so the raw Markdown of any page with an
  # uploaded image differs from one read to the next. The signature is
  # removed before hashing; the path, which names the file, is kept. Pages
  # without such URLs hash exactly as their raw Markdown does.
  module NotionDigest
    SIGNED_QUERY = %r{(https://[^\s)"'<>]+?)\?[^\s)"'<>]*X-Amz-[^\s)"'<>]*}

    module_function

    def of(markdown) = Digest::SHA256.hexdigest(stable(markdown))

    def stable(markdown) = markdown.to_s.gsub(SIGNED_QUERY, '\1')
  end
end
