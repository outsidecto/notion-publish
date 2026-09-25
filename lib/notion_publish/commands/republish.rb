# frozen_string_literal: true

require_relative "command"
require_relative "reporting"
require_relative "../decoration"
require_relative "../document"
require_relative "../publisher"
require_relative "../target"

module NotionPublish
  module Commands
    # Publishes every document the identity map tracks, from what each entry
    # recorded, without naming files one by one.
    #
    # Each page is updated where it already is, so no destination is needed
    # and none is accepted. Files the map does not track are left alone:
    # publishing a new document stays something you do on purpose.
    class Republish < Command
      include Reporting

      # Options that describe one document or one destination. They make no
      # sense applied to a whole set, so they are reported and ignored.
      IGNORED = {
        parent: "--parent", database: "--database", properties: "--property",
        properties_json: "--properties-json", title: "--title", icon: "--icon", cover: "--cover",
        keep_h1: "--keep-h1", link: "--link/--no-link", page: "--page", yes: "--yes", local: "--local"
      }.freeze

      SUMMARY = {
        unchanged: "unchanged", updated: "updated", properties: "properties updated", created: "recreated",
        blocked: "changed in Notion", skipped: "skipped", failed: "failed", orphaned: "no source file"
      }.freeze

      def call(dir)
        return dry_run_refused if options[:dry_run]

        warn_ignored
        map = page_map_in(dir)
        if map.created? || map.pages.empty?
          stderr.puts "Nothing published yet: no #{PageMap::FILENAME} with pages in #{dir}."
          return CLI::FAILURE
        end

        results = entries_under(map, File.expand_path(dir)).map { |key, raw| republish(map, key, raw) }
        stdout.puts summary(results) unless options[:json]
        exit_code(results)
      end

      private

      def publisher = @publisher ||= Publisher.new(client)

      def dry_run_refused
        stderr.puts "republish has no --dry-run. `notion-publish status` shows what it would do."
        CLI::USAGE
      end

      def warn_ignored
        given = IGNORED.filter_map { |key, flag| flag if options.key?(key) }
        return if given.empty?

        stderr.puts "Ignoring #{given.join(', ')}: republish updates each page where it already is, " \
                    "from what its entry recorded."
      end

      def entries_under(map, root)
        map.pages.select do |key, _|
          path = File.expand_path(key, map.dir)
          path == root || path.start_with?("#{root}#{File::SEPARATOR}")
        end
      end

      # Returns the action, or :failed. One document failing does not stop
      # the rest, the same as a shell loop without `|| break`.
      def republish(map, key, raw)
        entry = PageMap::Entry.from(raw)
        path = File.expand_path(key, map.dir)
        unless File.file?(path)
          stderr.puts "Skipped #{key}: no source file. Its Notion page is still live."
          return :orphaned
        end

        target = target_for(entry)
        warnings = []
        outcome = publish(path, entry, target, map, warnings)
        report(key, outcome, target, warnings)
        outcome.action
      rescue Error => e
        stderr.puts "Failed #{key}: #{e.message}"
        :failed
      end

      def publish(path, entry, target, map, warnings)
        document = Document.load(path)
        settings = settings_for(path)
        icon = document.icon || settings.icon
        cover = document.cover || settings.cover
        Decoration.check!(icon, :icon) if icon
        Decoration.check!(cover, :cover) if cover

        publisher.republish(document, entry: entry, target: target, map: map, warnings: warnings,
                                      upload: options[:upload] != false, icon: icon, cover: cover,
                                      force: options[:force] == true,
                                      force_properties: options[:force_properties] == true)
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

      def resolve_parent_of(entry)
        parent = client.get("/v1/pages/#{entry.id}")["parent"] || {}
        Resolver.new(client).resolve_reference(parent[parent["type"]].to_s)
      end

      def summary(results)
        counts = results.tally
        parts = SUMMARY.filter_map { |action, label| "#{counts[action]} #{label}" if counts[action] }
        "#{results.length} #{results.length == 1 ? 'document' : 'documents'}: #{parts.join(', ')}"
      end

      def exit_code(results)
        return CLI::FAILURE if results.include?(:failed)
        return CLI::BLOCKED if results.intersect?(%i[blocked skipped])

        CLI::OK
      end
    end
  end
end
