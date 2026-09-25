# frozen_string_literal: true

require_relative "../errors"
require_relative "../page_map"
require_relative "../progress"
require_relative "../property_set"
require_relative "../reference"
require_relative "../resolver"
require_relative "../settings"
require_relative "../target"

module NotionPublish
  module Commands
    # Shared plumbing: the invocation's options and streams, and the lookups
    # that more than one command needs.
    class Command
      PARENT_TYPES = %w[page_id database_id data_source_id].freeze
      MAX_DEPTH = 10

      def initialize(context)
        @context = context
      end

      private

      def options = @context.options
      def stdout = @stdout ||= progress.wrap(@context.stdout)
      def stderr = @stderr ||= progress.wrap(@context.stderr)
      def stdin = @context.stdin
      def client = @context.client
      def progress = @progress ||= Progress.new(@context.stderr, enabled: progress_wanted?)

      # Only on a terminal, and not when the request log is already showing
      # activity or --json output is being read by a program.
      def progress_wanted?
        terminal = @context.stderr.respond_to?(:tty?) && @context.stderr.tty?
        terminal && !options[:no_progress] && !logging_requests? && !options[:json]
      end

      # -v: list every file, including those where nothing happened.
      def listing_everything? = options[:verbose].to_i >= 1
      def logging_requests? = options[:verbose].to_i >= 2

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

      # The recorded parent is enough: the page is updated in place, and the
      # parent only supplies the schema. An adopted entry records none, so ask
      # Notion where the page lives.
      def target_for(entry)
        parent = entry.parent
        return resolve_parent_of(entry) unless parent

        Target.new(kind: parent["type"] == "page_id" ? :page : :data_source, id: parent["id"],
                   title: parent["name"], database_id: nil, inline: nil)
      end

      # A page's parent can be a block inside another page, such as a toggle
      # heading the page was moved under. Walk up until a page, database, or
      # data source appears; that is what supplies the schema.
      def resolve_parent_of(entry)
        parent = client.get("/v1/pages/#{entry.id}")["parent"] || {}
        MAX_DEPTH.times do
          type = parent["type"]
          return Resolver.new(client).resolve_reference(parent[type]) if PARENT_TYPES.include?(type)
          break unless type == "block_id"

          parent = client.get("/v1/blocks/#{parent['block_id']}")["parent"] || {}
        end
        raise Error, "Cannot tell which page or database #{entry.url} sits under."
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
