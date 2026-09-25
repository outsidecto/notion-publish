# frozen_string_literal: true

require "uri"

require_relative "errors"

module NotionPublish
  # Parses whatever a user types after --parent into a Notion UUID.
  #
  # Notion IDs appear in several shapes and every one of them shows up in the
  # wild: bare 32-character hex, dashed UUID, and URLs from notion.so,
  # app.notion.com, and workspace-prefixed paths, sometimes with a ?v= view ID
  # appended. Rather than matching URL structure, we take the last ID-shaped run
  # in the path, which is where Notion puts the object's own ID in every form.
  class Reference
    # Guard both ends so a 32-run inside a longer hex string does not match.
    HEX32 = /(?<![0-9a-fA-F])[0-9a-fA-F]{32}(?![0-9a-fA-F])/
    DASHED = /(?<![0-9a-fA-F-])\h{8}-\h{4}-\h{4}-\h{4}-\h{12}(?![0-9a-fA-F-])/

    # A whole string that is nothing but an ID.  Anchored on purpose: a loose
    # scan would read "Q3 Report 2efab123cd45..." as an ID when it is a badly
    # pasted name.
    BARE_ID = /\A(?:[0-9a-fA-F]{32}|\h{8}-\h{4}-\h{4}-\h{4}-\h{12})\z/
    URL_LIKE = %r{\A[a-z][a-z0-9+.-]*://|\Awww\.|notion\.(?:so|com)/}i

    attr_reader :input, :uuid, :slug_title

    def self.parse(input)
      new(input)
    end

    # Does this look like an ID or a URL, as opposed to a database name? Lets a
    # single --parent flag accept all three without ambiguity.
    def self.reference?(input)
      candidate = input.to_s.strip
      candidate.match?(BARE_ID) || candidate.match?(URL_LIKE)
    end

    def initialize(input)
      @input = input.to_s.strip
      raise InvalidReference, @input if @input.empty?

      path = strip_query(@input)
      @uuid = extract_uuid(path) or raise InvalidReference, @input
      @slug_title = extract_slug_title(path)
    end

    def to_s = uuid

    private

    def strip_query(str)
      str.split("#", 2).first.to_s.split("?", 2).first.to_s
    end

    def extract_uuid(path)
      if (dashed = path.scan(DASHED).last)
        dashed.downcase
      elsif (hex = path.scan(HEX32).last)
        dash(hex.downcase)
      end
    end

    def dash(hex)
      [hex[0, 8], hex[8, 4], hex[12, 4], hex[16, 4], hex[20, 12]].join("-")
    end

    # A Notion URL carries the page title in its slug. The API will not tell us
    # the title of a page we cannot read, so this is the only way to name the
    # object back to the user in a 404 message.
    def extract_slug_title(path)
      segment = path.split("/").reject(&:empty?).last.to_s
      slug = segment.sub(HEX32, "").sub(DASHED, "").sub(/-+\z/, "")
      return nil if slug.empty? || slug == segment

      decoded = begin
        URI.decode_www_form_component(slug)
      rescue ArgumentError
        slug
      end
      decoded.tr("-", " ").squeeze(" ").strip
    end
  end
end
