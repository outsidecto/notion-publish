# frozen_string_literal: true

require "json"

require_relative "command"
require_relative "../status"

module NotionPublish
  module Commands
    # What would happen if you published everything. Exits 3 when a tracked
    # document needs something done to it, so it works as a CI check. Files
    # that were never published do not count: plenty are deliberately not
    # mirrored.
    class Status < Command
      def call(dir)
        map = page_map_in(dir)
        if map.created?
          stderr.puts "Nothing published yet: no #{PageMap::FILENAME} at or above #{dir}."
          return CLI::FAILURE
        end

        check = options[:local] != true
        rows = NotionPublish::Status.new(map, client: check ? client : nil).rows(dir: dir, check_notion: check)
        options[:json] ? print_json(rows) : print_text(map, rows, check)
        rows.any?(&:actionable?) ? CLI::BLOCKED : CLI::OK
      end

      private

      def print_json(rows)
        rows.each do |row|
          stdout.puts JSON.generate("source" => row.source, "state" => row.state.to_s, "url" => row.url)
        end
      end

      def print_text(map, rows, checked)
        tracked = rows.reject { |r| r.state == :unpublished }
        stdout.puts "#{map.path} -- #{tracked.length} tracked"
        stdout.puts "(not checked against Notion; --local was given)" unless checked
        stdout.puts

        rows.reject { |r| r.state == :unchanged }.each { |row| print_row(row) }

        counts = rows.group_by(&:state).transform_values(&:length)
        stdout.puts if counts.length > 1 || !counts.key?(:unchanged)
        stdout.puts summary(counts)
      end

      def print_row(row)
        stdout.puts format("  %-18s %s", row.label, row.source)
        stdout.puts format("  %-18s %s", "", row.url) if row.url && row.state != :modified
      end

      def summary(counts)
        return "Everything is in sync." if counts.empty? || counts.keys == [:unchanged]

        NotionPublish::Status::STATES.filter_map { |state, label| "#{counts[state]} #{label}" if counts[state] }
                                     .join(", ")
      end
    end
  end
end
