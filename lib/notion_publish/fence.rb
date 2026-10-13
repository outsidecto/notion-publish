# frozen_string_literal: true

module NotionPublish
  # Follows fenced code blocks through a Markdown body, one line at a time.
  #
  # CommonMark closes a fence only with a run of the same character, at least
  # as long as the opening one, and nothing after it. So a ```` fence can show
  # a ``` example, and a ``` line inside a ~~~ fence is just code. Toggling on
  # any line that starts with three backticks gets both wrong.
  #
  # Indentation is not checked against the enclosing list item: a fence
  # indented under a list item is still a fence.
  class Fence
    OPEN = /\A(\s*)(`{3,}|~{3,})(.*)\z/
    # Notion ends a code block at any line starting with three backticks, even
    # one with a label after them, and its Markdown has no way around that.
    NOTION_FENCE = /\A\s*```/

    # The opening line's indentation, fence characters, and first word of the
    # info string (the language), or nil outside a fence.
    Opening = Data.define(:indent, :marker, :language)

    attr_reader :opening

    def inside? = !opening.nil?

    # Whether Notion's Markdown parser would cut these lines of code short.
    def self.too_deep_for_notion?(code) = code.any? { |line| line.match?(NOTION_FENCE) }

    # Feeds one line. Returns :open, :close, or :code for a fence line or a
    # line of code, and nil for an ordinary line.
    def step(line)
      text = line.chomp
      return enter(text) unless inside?

      return :code unless closes?(text)

      @opening = nil
      :close
    end

    private

    def enter(text)
      match = text.match(OPEN)
      return nil unless match

      marker = match[2]
      info = match[3].strip
      # A backtick fence's info string may not contain a backtick; otherwise
      # the line is inline code, not a fence.
      return nil if marker.start_with?("`") && info.include?("`")

      @opening = Opening.new(indent: match[1], marker: marker, language: info.split.first)
      :open
    end

    def closes?(text)
      char = Regexp.escape(opening.marker[0])
      text.match?(/\A\s*#{char}{#{opening.marker.length},}\s*\z/)
    end
  end
end
