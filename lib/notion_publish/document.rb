# frozen_string_literal: true

require "date"
require "yaml"

require_relative "errors"

module NotionPublish
  # A Markdown file, split into optional YAML front matter and a body.
  class Document
    FRONT_MATTER = /\A---[ \t]*\r?\n(.*?\r?\n)---[ \t]*(?:\r?\n|\z)/m

    attr_reader :path, :front_matter, :body

    def self.load(path)
      raise Error, "No such file: #{path}" unless File.file?(path)

      new(path, File.read(path))
    end

    def initialize(path, source)
      @path = path
      @front_matter, @body = split(source)
    end

    # A copy with a transformed body, keeping the path and front matter.
    def with_body(body)
      dup.tap { |copy| copy.body = body }
    end

    def title
      from_front_matter = front_matter["title"]
      return from_front_matter.to_s if from_front_matter && !from_front_matter.to_s.empty?

      first_heading || File.basename(path, File.extname(path))
    end

    # Notion property values live under a "properties:" key so they can never
    # collide with the tool's own front-matter keys.
    def properties = front_matter["properties"]

    def icon = front_matter["notion_icon"]
    def cover = front_matter["notion_cover"]

    def parent = front_matter["notion_parent"]
    def database = front_matter["notion_database"]

    protected

    attr_writer :body

    private

    def first_heading
      body.each_line do |line|
        return Regexp.last_match(1).strip if line =~ /\A\#\s+(.+)/
      end
      nil
    end

    def split(source)
      match = source.match(FRONT_MATTER)
      return [{}, source] unless match

      parsed = begin
        YAML.safe_load(match[1], permitted_classes: [Date, Time], aliases: false) || {}
      rescue Psych::Exception => e
        raise Error, "Could not parse front matter in #{path}: #{e.message}"
      end
      raise Error, "Front matter in #{path} must be a YAML mapping" unless parsed.is_a?(Hash)

      [parsed, match.post_match]
    end
  end
end
