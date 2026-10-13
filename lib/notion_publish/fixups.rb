# frozen_string_literal: true

require_relative "fence"
require_relative "languages"

module NotionPublish
  # Line-level corrections applied to a Markdown body before Notion parses it.
  #
  # Notion accepts CommonMark and GFM well -- tables, nesting, task lists, code
  # fences all survive -- with one systematic exception: it does not honour soft
  # line breaks. CommonMark treats consecutive non-blank lines as one paragraph;
  # Notion makes a separate block out of each line. Any document wrapped at a
  # column width therefore arrives looking double-spaced, and wrapped list items
  # break out of their list entirely.
  #
  # So each run of lines that CommonMark would treat as one block is joined back
  # into one line before sending. A space, not <br>: the wrapping is an artifact
  # of how the file is stored, not something the author meant to be seen. Only
  # an explicit hard break -- two trailing spaces, or a trailing backslash --
  # becomes <br>, which is what Notion's own markdown output uses.
  #
  # GitHub alerts (a blockquote whose first line is "> [!NOTE]" and the like)
  # mean nothing to Notion, which shows the marker as literal text in a quote.
  # They become callouts instead, with an icon and colour per alert type.
  #
  # Notion's parser also reads only three-backtick fences, and guesses a
  # language when the label is missing, has extra words, or is one it does
  # not know. So every fence is rewritten as ``` with Notion's name for its
  # language, or "plain text". Code Notion's parser cannot hold at all is left
  # for CodeBlocks.
  module Fixups
    BLANK = /\A\s*\z/
    HEADING = /\A {0,3}\#{1,6}(?:\s|\z)/
    THEMATIC = /\A {0,3}([-*_])(?:\s*\1){2,}\s*\z/
    TABLE = /\A {0,3}\|/
    HTML = /\A {0,3}</
    INDENTED_CODE = /\A {4,}\S/
    # An image alone on its line. Joined into the line above, it would become
    # an image inside a sentence, which Notion cannot show.
    IMAGE_LINE = /\A\s*!\[[^\]]*\]\([^)]*\)\s*\z/
    QUOTE = /\A {0,3}>[ \t]?(.*)\z/
    LIST = /\A(\s*(?:[-*+]|\d+[.)])\s+)(.*)\z/
    HARD_BREAK = /(?: {2,}|\\)\z/
    # GitHub only recognises the marker alone on the first line of a top-level
    # blockquote, in any letter case.
    ALERT = /\A {0,3}>[ \t]*\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\][ \t]*\z/i
    # GitHub's colours for each type, as Notion background colours.
    ALERT_STYLES = {
      "NOTE" => ["📘", "blue_bg"],
      "TIP" => ["💡", "green_bg"],
      "IMPORTANT" => ["❗", "purple_bg"],
      "WARNING" => ["⚠️", "yellow_bg"],
      "CAUTION" => ["🛑", "red_bg"]
    }.freeze

    module_function

    def apply(body) = join_soft_wraps(normalize_fences(body))

    # Rewrites each fence as Notion's parser understands it: three backticks
    # and Notion's name for the language, or "plain text". The code
    # inside is untouched. An unclosed fence stays unclosed, since Notion, like
    # CommonMark, runs it to the end of the document.
    def normalize_fences(body)
      out = []
      block = nil
      fence = Fence.new

      body.to_s.lines.each do |raw|
        case fence.step(raw)
        when :open then block = { opening: fence.opening, lines: [raw] }
        when :code then block[:lines] << raw
        when :close
          out.concat(rewrite_fence(block, raw))
          block = nil
        else out << raw
        end
      end

      out.concat(rewrite_fence(block, nil)) if block
      out.join
    end

    # Code with a line Notion would read as a fence cannot be written in a form
    # its parser keeps whole. That block is left as written, for CodeBlocks to
    # send through the block API.
    def rewrite_fence(block, closing)
      opening, *code = block[:lines]
      return [opening, *code, *closing] if Fence.too_deep_for_notion?(code)

      start = block[:opening]
      opened = "#{start.indent}```#{Languages.notion_name(start.language)}\n"
      [opened, *code, *(closing && "#{closing[/\A\s*/]}```\n")]
    end

    # Notion consumes a leading H1 as the page title -- but only when it is the
    # document's *only* H1. A second one anywhere (a "# Revision History" at the
    # foot is enough) makes it keep both, and the title then appears twice: once
    # as the page title, once as a heading. Removing it here makes the result
    # the same either way.
    def strip_leading_h1(body)
      lines = body.to_s.lines
      index = lines.index { |line| !line.match?(BLANK) }
      return body unless index && lines[index].match?(/\A {0,3}\#(?!\#)\s/)

      rest = lines[(index + 1)..] || []
      rest.shift while rest.first&.match?(BLANK)
      # Blank lines ahead of the title go with it.
      rest.join
    end

    def join_soft_wraps(body)
      lines = body.to_s.lines
      out = []
      run = nil
      fence = Fence.new
      index = 0

      while index < lines.length
        raw = lines[index]

        if fence.step(raw)
          out.concat(flush(run)) << raw
          run = nil
        elsif (alert = alert_at(lines, index))
          type, inner, index = alert
          out.concat(flush(run)).concat(callout(type, inner))
          run = nil
          next
        else
          run, emitted = classify(raw.chomp, raw, run)
          out.concat(emitted)
        end
        index += 1
      end

      out.concat(flush(run))
      out.join
    end

    # Returns [type, inner_markdown, index_after] when an alert starts at
    # lines[start], or nil. The alert runs to the last line of its blockquote.
    def alert_at(lines, start)
      type = lines[start].chomp[ALERT, 1]
      return nil unless type
      return nil if start.positive? && lines[start - 1].chomp.match?(QUOTE)

      finish = start + 1
      inner = []
      while finish < lines.length && (match = lines[finish].chomp.match(QUOTE))
        inner << "#{match[1]}\n"
        finish += 1
      end
      # A marker with nothing under it is an ordinary quote on GitHub too.
      return nil if inner.all? { |text| text.match?(BLANK) }

      [type.upcase, inner.join, finish]
    end

    # Each line of the alert's body, already joined, is indented one tab to sit
    # inside the callout.
    def callout(type, inner)
      icon, color = ALERT_STYLES.fetch(type)
      body = apply(inner).lines.map { |text| text.match?(BLANK) ? "\n" : "\t#{text}" }
      body.shift while body.first == "\n"
      body.pop while body.last == "\n"

      ["<callout icon=\"#{icon}\" color=\"#{color}\">\n", *body, "</callout>\n"]
    end

    # Returns [new_run, lines_to_emit].
    def classify(line, raw, run)
      case line
      when IMAGE_LINE
        # Set apart from the text above, keeping its indentation, so an image
        # written under a list item stays inside that item.
        [nil, flush(run) + (run ? ["\n", raw] : [raw])]
      when BLANK, THEMATIC, HEADING, TABLE, HTML
        [nil, flush(run) + [raw]]
      when QUOTE
        quote(Regexp.last_match(1), line, run)
      when LIST
        [{ kind: :list, prefix: Regexp.last_match(1), parts: [part(Regexp.last_match(2), line)] }, flush(run)]
      when INDENTED_CODE
        run ? [continue(run, line), []] : [nil, flush(run) + [raw]]
      else
        continuation(line, run)
      end
    end

    # A bare ">" separates paragraphs inside a quote, so it ends the run rather
    # than joining the halves together.
    def quote(text, line, run)
      return [nil, flush(run) + ["#{line}\n"]] if text.strip.empty?
      return [continue(run, line, text), []] if run && run[:kind] == :quote

      [{ kind: :quote, prefix: "> ", parts: [part(text, line)] }, flush(run)]
    end

    def continuation(line, run)
      return [continue(run, line), []] if run

      [{ kind: :paragraph, prefix: "", parts: [part(line, line)] }, []]
    end

    def continue(run, line, text = line)
      run.merge(parts: run[:parts] + [part(text, line)])
    end

    def part(text, line)
      hard = line.match?(HARD_BREAK)
      # A trailing backslash is the break marker itself, not content.
      { text: text.strip.sub(/\\\z/, "").rstrip, hard: hard }
    end

    def flush(run)
      return [] unless run

      joined = +""
      run[:parts].each_with_index do |piece, index|
        joined << (run[:parts][index - 1][:hard] ? "<br>" : " ") unless index.zero?
        joined << piece[:text]
      end

      ["#{run[:prefix]}#{joined}\n"]
    end
  end
end
