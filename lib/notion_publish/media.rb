# frozen_string_literal: true

module NotionPublish
  # Finds local image references in a Markdown body.
  #
  # Notion's `markdown` parameter can only express *external* file references.
  # A local path, an upload id, or anything else produces an image block with an
  # empty URL -- and it does so without an error, so a dropped diagram looks
  # like a successful publish. Local images therefore have to be uploaded and
  # attached through the block API instead.
  #
  # To keep the server-side Markdown parser for everything else, each local
  # image is swapped for a sentinel paragraph before publishing. The sentinel is
  # located afterwards and the real image block is inserted in its place.
  class Media
    FENCE = /\A\s*(?:`{3,}|~{3,})/
    # An image alone on its line. Only these can become blocks: Notion has no
    # inline image, so an image sitting inside a sentence has nowhere to go.
    STANDALONE = /\A\s*!\[([^\]]*)\]\(\s*([^)\s]+?)\s*(?:"[^"]*")?\s*\)\s*\z/
    ANY_IMAGE = /!\[[^\]]*\]\([^)]*\)/
    EXTERNAL = %r{\Ahttps?://}i

    Image = Data.define(:index, :alt, :path) do
      def sentinel = format("NOTIONPUBLISHIMAGE%04d", index)
    end

    attr_reader :images, :inline_paths

    def self.scan(body, base_dir:) = new(body, base_dir: base_dir)

    def initialize(body, base_dir:)
      @body = body.to_s
      @base_dir = base_dir
      @images = []
      @inline_paths = []
      @rewritten = rewrite
    end

    def any? = !images.empty?

    # The body with each local image replaced by its sentinel, ready to send as
    # the `markdown` parameter.
    def body_with_sentinels = @rewritten

    def resolved_path(image) = File.expand_path(image.path, @base_dir)

    private

    def rewrite
      in_fence = false
      index = 0

      lines = @body.lines.map do |line|
        if line.match?(FENCE)
          in_fence = !in_fence
          next line
        end
        next line if in_fence

        match = line.match(STANDALONE)
        if match && local?(match[2])
          image = Image.new(index: index, alt: match[1], path: unescape(match[2]))
          @images << image
          index += 1
          next "#{image.sentinel}\n"
        end

        # An image among other text cannot become a block. Note it so the caller
        # can say so rather than letting it publish as an empty URL.
        collect_inline(line) if match.nil? && line.match?(ANY_IMAGE)
        line
      end

      lines.join
    end

    def collect_inline(line)
      line.scan(/!\[[^\]]*\]\(\s*([^)\s]+?)\s*(?:"[^"]*")?\s*\)/) do |(url)|
        @inline_paths << url if local?(url)
      end
    end

    # Anything that is not a well-formed http(s) URL has to be treated as local.
    # A malformed URL produces the same silent empty-URL block that a relative
    # path does, so guessing charitably here would hide the failure.
    def local?(url) = !url.to_s.match?(EXTERNAL)

    def unescape(url) = url.to_s.gsub("%20", " ").delete_prefix("<").delete_suffix(">")
  end
end
