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
      # Problems first, then what is in sync, then what was never published.
      ORDER = (NotionPublish::Status::ACTIONABLE + %i[unchanged unpublished]).freeze
      # States where the page itself is what needs looking at.
      SHOW_URL = %i[drifted diverged missing trashed orphaned].freeze

      def call(dir)
        map = page_map_in(dir)
        if map.created?
          stderr.puts "Nothing published yet: no #{PageMap::FILENAME} at or above #{dir}."
          return CLI::FAILURE
        end

        check = options[:local] != true
        progress.start("Checking", map.pages.length)
        rows = NotionPublish::Status.new(map, client: check ? client : nil)
                                    .rows(dir: dir, check_notion: check, on_row: ->(key) { progress.step(key) })
        progress.finish
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
        tracked = rows.count { |r| r.state != :unpublished }
        stdout.puts "#{map.path} -- #{tracked} tracked"
        stdout.puts "(not checked against Notion; --local was given)" unless checked

        groups = rows.group_by(&:state)
        ORDER.each { |state| print_group(state, groups[state]) if groups[state] }

        stdout.puts
        stdout.puts summary(groups.transform_values(&:length))
      end

      def print_group(state, rows)
        return if state == :unchanged && options[:quiet]

        label = NotionPublish::Status::STATES[state]
        heading = "#{label[0].upcase}#{label[1..]} (#{rows.length})"
        stdout.puts
        if state == :unpublished && !options[:untracked]
          stdout.puts "#{heading}: pass --untracked to list them"
          return
        end

        stdout.puts heading
        rows.each do |row|
          stdout.puts "  #{row.source}"
          stdout.puts "    #{row.url}" if row.url && SHOW_URL.include?(state)
        end
      end

      def summary(counts)
        return "Everything is in sync." if counts.empty? || counts.keys == [:unchanged]

        NotionPublish::Status::STATES.filter_map { |state, label| "#{counts[state]} #{label}" if counts[state] }
                                     .join(", ")
      end
    end
  end
end
