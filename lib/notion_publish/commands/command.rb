# frozen_string_literal: true

require_relative "../errors"
require_relative "../page_map"
require_relative "../property_set"
require_relative "../reference"
require_relative "../resolver"
require_relative "../settings"

module NotionPublish
  module Commands
    # Shared plumbing: the invocation's options and streams, and the lookups
    # that more than one command needs.
    class Command
      def initialize(context)
        @context = context
      end

      private

      def options = @context.options
      def stdout = @context.stdout
      def stderr = @context.stderr
      def stdin = @context.stdin
      def client = @context.client

      def map_reporter = ->(message) { stderr.puts message }

      def settings_for(path)
        Settings.for(File.dirname(File.expand_path(path)))
      end

      # First match wins: command line, then front matter, then settings.
      def resolve_destination(document, settings)
        resolver = Resolver.new(client)

        if (parent = options[:parent] || document.parent || settings.parent)
          return resolver.resolve(parent)
        end

        name = options[:database] || document.database || settings.database
        return resolver.resolve_database_name(name) if name

        raise Error, no_destination_message
      end

      def property_set(document)
        PropertySet.build(front_matter: document.properties, json: options[:properties_json],
                          pairs: options[:properties] || [])
      end

      def page_map_in(dir)
        PageMap.locate_in(File.expand_path(dir), override: options[:pages_file], reporter: map_reporter)
      end

      def no_destination_message
        <<~MSG.strip
          No destination. Notion needs a parent for every page, and an internal
          connection cannot create pages at the workspace root.

          Give one of these:
            --parent <ID, Notion URL, or exact database name>
            --database <exact database name>

          Or set notion_parent / notion_database in the file's front matter, or
          parent / database in #{Settings::FILENAME}.
        MSG
      end
    end
  end
end
