# frozen_string_literal: true

require_relative "fence"
require_relative "languages"

module NotionPublish
  # Finds code that Notion's Markdown parser cannot hold.
  #
  # Notion ends a code block at any line starting with three backticks, and its
  # parser reads no longer fence that could get around it. A ```` fence showing
  # a ``` example, the usual thing in a document about writing Markdown, comes
  # out as broken code and stray paragraphs. Notion's own Markdown export has
  # the same problem, so there is no form of the text that survives.
  #
  # Such a block is therefore swapped for a sentinel paragraph, like a local
  # image, and the real code block is inserted through the block API after the
  # page is written.
  class CodeBlocks
    # Notion allows 2,000 characters in one rich-text item, and may count an
    # emoji as two, so the code is cut into pieces of half that. A block holds
    # at most 100 items.
    TEXT_CHUNK = 1000
    ITEMS_LIMIT = 100

    Block = Data.define(:index, :language, :code) do
      def sentinel = format("NOTIONPUBLISHCODE%04d", index)

      # The code block, or several if the code is past Notion's limits.
      def to_notion
        pieces = code.empty? ? [""] : code.scan(/.{1,#{TEXT_CHUNK}}/m)
        rich_text = pieces.map { |text| { "type" => "text", "text" => { "content" => text } } }
        rich_text.each_slice(ITEMS_LIMIT).map do |slice|
          { "type" => "code", "code" => { "language" => language, "rich_text" => slice } }
        end
      end
    end

    attr_reader :blocks, :body

    def self.scan(body) = new(body)

    def initialize(body)
      @blocks = []
      @body = rewrite(body.to_s)
    end

    def any? = !blocks.empty?

    private

    def rewrite(body)
      out = []
      pending = nil
      fence = Fence.new

      body.lines.each do |raw|
        case fence.step(raw)
        when :open then pending = { opening: fence.opening, lines: [raw] }
        when :code then pending[:lines] << raw
        when :close
          out.concat(settle(pending, raw))
          pending = nil
        else out << raw
        end
      end

      out.concat(settle(pending, nil)) if pending
      out.join
    end

    # The fence as written, or a sentinel in its place if Notion cannot hold it.
    def settle(pending, closing)
      opening, *code = pending[:lines]
      return [opening, *code, *closing] unless Fence.too_deep_for_notion?(code)

      start = pending[:opening]
      block = Block.new(index: blocks.length, language: Languages.notion_name(start.language),
                        code: unindent(code, start.indent).join.chomp)
      @blocks << block
      ["#{start.indent}#{block.sentinel}\n"]
    end

    # CommonMark removes up to the fence's own indentation from each line of
    # code, so code under a list item or in a callout is not shifted right.
    def unindent(code, indent)
      return code if indent.empty?

      code.map { |line| line.sub(/\A[ \t]{0,#{indent.length}}/, "") }
    end
  end
end
