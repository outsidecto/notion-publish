# frozen_string_literal: true

require "digest"

require_relative "../notion_digest"
require_relative "command"
require_relative "../links"
require_relative "../pool"

module NotionPublish
  module Commands
    # The second pass after publishing a set. A document published before the
    # one it links to could not resolve that link, so Notion stored it as
    # https://<filename>.md. Now that every page has a URL, fix those.
    class Relink < Command
      def call(dir)
        map = manifest_in(dir)
        if map.created? || map.pages.empty?
          stderr.puts "Nothing published yet: no #{Manifest::FILENAME} with pages in #{dir}."
          return CLI::FAILURE
        end

        fixed = relink_all(map).sum
        report_orphans(map)
        stdout.puts fixed.zero? ? "No links needed fixing." : "Fixed #{fixed} #{plural(fixed, 'link')}."
        CLI::OK
      end

      private

      # Several pages at a time. Workers read the published URLs from a copy
      # taken first, since the manifest itself changes as pages are rehashed.
      def relink_all(map)
        urls = map.pages.transform_values { |raw| raw["url"] }
        client
        progress.start("Checking", map.pages.length)
        Pool.run(map.pages.to_a, size: jobs, work: lambda { |(key, raw)|
          relink_page(map, urls, key, Manifest::Entry.from(raw))
        },
                                 started: ->((key, _)) { progress.started(key) },
                                 finished: ->(done) { progress.finished(done) }) do |(key, _), count|
          stdout.puts "#{File.basename(key)}: fixed #{count} #{plural(count, 'link')}" if count.positive?
        end
      ensure
        progress.finish
      end

      # Returns the number of links fixed.
      def relink_page(map, urls, key, entry)
        before = read_markdown(entry.id)
        updates = pending_updates(urls, before)
        return 0 if updates.empty?

        client.patch("/v1/pages/#{entry.id}/markdown",
                     { "type" => "update_content", "update_content" => { "content_updates" => updates } })
        rehash(map, key, entry, before)
        updates.length
      end

      # The page now differs from what was recorded after publishing, and it
      # was this tool that changed it. Record the new content, or the next
      # status would call it an edit made in Notion. Only when the page was in
      # sync beforehand: an edit someone else made must stay visible.
      def rehash(map, key, entry, before)
        return unless entry.notion_sha256 == NotionDigest.of(before)

        after = NotionDigest.of(read_markdown(entry.id))
        map.record(File.expand_path(key, map.dir), entry.with(notion_sha256: after))
      end

      def read_markdown(page_id) = client.get("/v1/pages/#{page_id}/markdown")["markdown"].to_s

      def pending_updates(urls, markdown)
        urls.filter_map do |key, url|
          mangled = Links.mangled(File.basename(key))
          next unless markdown.include?("](#{mangled})")

          { "old_str" => "](#{mangled})", "new_str" => "](#{url})", "replace_all_matches" => true }
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
