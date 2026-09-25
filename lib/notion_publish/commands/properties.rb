# frozen_string_literal: true

require_relative "command"
require_relative "../document"
require_relative "../schema"

module NotionPublish
  module Commands
    # Lists the destination's properties, their types, and the options a
    # select can take, so a user can see what --property will accept.
    class Properties < Command
      def call
        target = resolve_destination(Document.new("(none)", ""), Settings.for(Dir.pwd))
        schema = Schema.for(client, target)

        stdout.puts target.describe
        schema.properties.each { |name, definition| print_property(name, definition) }
        CLI::OK
      end

      private

      def print_property(name, definition)
        type = definition["type"]
        note = Schema::COMPUTED.include?(type) ? " (read-only)" : ""
        stdout.puts format("  %-24s %s%s", name, type, note)

        choices = definition.dig(type, "options")
        stdout.puts "    #{choices.map { |o| o['name'] }.join(' | ')}" if choices && !choices.empty?
      end
    end
  end
end
