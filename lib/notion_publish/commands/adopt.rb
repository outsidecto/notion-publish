# frozen_string_literal: true

require "digest"

require_relative "../notion_digest"
require_relative "command"
require_relative "../adopter"
require_relative "../document"

module NotionPublish
  module Commands
    # Records that a local file and an existing Notion page are the same
    # document. Changes neither.
    #
    # Deliberately does not record source_sha256: adoption asserts identity,
    # not that the page already holds this content, so the next publish always
    # runs rather than reporting it unchanged.
    class Adopt < Command
      def call(path)
        document = Document.load(path)
        map = PageMap.locate(path, override: options[:pages_file], reporter: map_reporter)
        source = File.expand_path(path)

        if (existing = map.entry(source))
          raise Error, already_adopted(path, existing)
        end

        candidate = choose(document, path)
        return CLI::FAILURE unless candidate

        record(map, source, candidate)
        stdout.puts "Adopted #{path}"
        stdout.puts "  #{candidate.url}"
        stdout.puts "Run notion-publish to update it."
        CLI::OK
      end

      private

      def record(map, source, candidate)
        markdown = client.get("/v1/pages/#{candidate.id}/markdown")["markdown"].to_s
        map.workspace_id = client.me.dig("bot", "workspace_id")
        map.record(source, PageMap::Entry.new(id: candidate.id, url: candidate.url,
                                              notion_sha256: NotionDigest.of(markdown),
                                              flag_properties: []))
      end

      def choose(document, path)
        adopter = Adopter.new(client)
        return adopter.by_page(options[:page]) if options[:page]

        target = resolve_destination(document, settings_for(path))
        title = options[:title] || document.title
        found = adopter.by_title(target, title)

        case found.length
        when 1 then confirm(found.first, target, title)
        when 0 then raise Error, nothing_matches(title, target)
        else raise Error, too_many(title, target, found)
        end
      end

      def confirm(candidate, target, title)
        return candidate if options[:yes]
        raise Error, needs_a_terminal(candidate, title) unless stdin.tty?

        stdout.puts "One page in #{target.title.inspect} is titled #{title.inspect}:"
        stdout.puts "  #{candidate.url}"
        stdout.puts "  last edited #{candidate.last_edited_time.to_s[0, 10]} by #{candidate.last_edited_by}"
        stdout.puts
        stdout.puts "Adopting means the next publish will replace that page's contents."
        stdout.print "Adopt it? [y/N] "
        candidate if stdin.gets.to_s.strip.casecmp?("y")
      end

      def already_adopted(path, entry)
        <<~MSG.strip
          #{path} already points at a page:
            #{entry.url}

          Delete that entry from #{PageMap::FILENAME} first if you meant to point it
          somewhere else.
        MSG
      end

      def nothing_matches(title, target)
        <<~MSG.strip
          No page in #{target.title.inspect} is titled #{title.inspect}.

          Nothing to adopt. Publish it instead:
            notion-publish <file> --parent #{target.title.inspect}
        MSG
      end

      def too_many(title, target, found)
        lines = ["More than one page in #{target.title.inspect} is titled #{title.inspect}:", ""]
        found.each { |c| lines << "  #{c.url}" }
        lines << "" << "Choose one with --page <url>."
        lines.join("\n")
      end

      def needs_a_terminal(candidate, title)
        <<~MSG.strip
          Found one page titled #{title.inspect}:
            #{candidate.url}

          Adopting replaces that page's contents on the next publish, and there is
          no terminal here to confirm it. Pass --yes to answer in advance, or
          --page <url> to name the page outright.
        MSG
      end
    end
  end
end
