# frozen_string_literal: true

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
  module Fixups
    FENCE = /\A\s*(?:`{3,}|~{3,})/
    BLANK = /\A\s*\z/
    HEADING = /\A {0,3}\#{1,6}(?:\s|\z)/
    THEMATIC = /\A {0,3}([-*_])(?:\s*\1){2,}\s*\z/
    TABLE = /\A {0,3}\|/
    HTML = /\A {0,3}</
    INDENTED_CODE = /\A {4,}\S/
    QUOTE = /\A {0,3}>[ \t]?(.*)\z/
    LIST = /\A(\s*(?:[-*+]|\d+[.)])\s+)(.*)\z/
    HARD_BREAK = /(?: {2,}|\\)\z/

    module_function

    def apply(body) = join_soft_wraps(body)

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
      out = []
      run = nil
      in_fence = false

      body.to_s.lines.each do |raw|
        line = raw.chomp

        if line.match?(FENCE)
          out.concat(flush(run))
          run = nil
          in_fence = !in_fence
          out << raw
          next
        end

        if in_fence
          out << raw
          next
        end

        run, emitted = classify(line, raw, run)
        out.concat(emitted)
      end

      out.concat(flush(run))
      out.join
    end

    # Returns [new_run, lines_to_emit].
    def classify(line, raw, run)
      case line
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
