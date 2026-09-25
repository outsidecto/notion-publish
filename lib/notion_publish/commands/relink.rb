# frozen_string_literal: true

require_relative "command"
require_relative "../links"

module NotionPublish
  module Commands
    # The second pass after publishing a set. A document published before the
    # one it links to could not resolve that link, so Notion stored it as
    # https://<filename>.md. Now that every page has a URL, fix those.
    class Relink < Command
      def call(dir)
        map = page_map_in(dir)
        if map.created? || map.pages.empty?
          stderr.puts "Nothing published yet: no #{PageMap::FILENAME} with pages in #{dir}."
          return CLI::FAILURE
        end

        fixed = map.pages.sum { |key, raw| relink_page(map, key, PageMap::Entry.from(raw)) }
        report_orphans(map)
        stdout.puts fixed.zero? ? "No links needed fixing." : "Fixed #{fixed} #{plural(fixed, 'link')}."
        CLI::OK
      end

      private

      def relink_page(map, key, entry)
        updates = pending_updates(map, entry.id)
        return 0 if updates.empty?

        client.patch("/v1/pages/#{entry.id}/markdown",
                     { "type" => "update_content", "update_content" => { "content_updates" => updates } })
        stdout.puts "#{File.basename(key)}: fixed #{updates.length} #{plural(updates.length, 'link')}"
        updates.length
      end

      def pending_updates(map, page_id)
        markdown = client.get("/v1/pages/#{page_id}/markdown")["markdown"].to_s

        map.pages.filter_map do |key, raw|
          mangled = Links.mangled(File.basename(key))
          next unless markdown.include?("](#{mangled})")

          { "old_str" => "](#{mangled})", "new_str" => "](#{raw['url']})", "replace_all_matches" => true }
        end
      end

      # The tool cannot tell a retirement from a rename, so it reports and stops.
      def report_orphans(map)
        orphans = map.orphans
        return if orphans.empty?

        stderr.puts "#{orphans.length} #{orphans.length == 1 ? 'entry has' : 'entries have'} no source file:"
        orphans.each { |key| stderr.puts "  #{key}" }
        stderr.puts "Their Notion pages are still live. Remove them there if they are retired."
      end

      def plural(count, word) = count == 1 ? word : "#{word}s"
    end
  end
end
