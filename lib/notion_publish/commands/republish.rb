# frozen_string_literal: true

require_relative "command"
require_relative "reporting"
require_relative "../decoration"
require_relative "../document"
require_relative "../pool"
require_relative "../publisher"
require_relative "../target"

module NotionPublish
  module Commands
    # Publishes every document the manifest tracks, from what each entry
    # recorded, without naming files one by one.
    #
    # Each page is updated where it already is, so no destination is needed
    # and none is accepted. Files the manifest does not track are left alone:
    # publishing a new document stays something you do on purpose.
    class Republish < Command
      include Reporting

      # Options that describe one document or one destination. They make no
      # sense applied to a whole set, so they are reported and ignored.
      IGNORED = {
        parent: "--parent", database: "--database", properties: "--property",
        properties_json: "--properties-json", title: "--title", icon: "--icon", cover: "--cover",
        keep_h1: "--keep-h1", link: "--link/--no-link", page: "--page", yes: "--yes", local: "--local",
        untracked: "--untracked"
      }.freeze

      SUMMARY = {
        unchanged: "unchanged", updated: "updated", properties: "properties updated", created: "recreated",
        blocked: "changed in Notion", skipped: "skipped", failed: "failed", orphaned: "no source file"
      }.freeze

      def call(dir)
        return dry_run_refused if options[:dry_run]

        warn_ignored
        map = manifest_in(dir)
        if map.created? || map.pages.empty?
          stderr.puts "Nothing published yet: no #{Manifest::FILENAME} with pages in #{dir}."
          return CLI::FAILURE
        end

        entries = entries_under(map, File.expand_path(dir)).to_a
        results = run_all(map, entries).map(&:action)
        stdout.puts summary(results) unless options[:json]
        exit_code(results)
      end

      private

      def publisher = @publisher ||= Publisher.new(client)
      def show_unchanged? = listing_everything?

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

      # What republishing one file came to. Built on a worker thread and
      # printed on the calling one, in file order.
      Result = Data.define(:key, :action, :outcome, :target, :warnings, :message)

      # Several files at a time. The client, the publisher, and the manifest are
      # set up here first, so no worker races to create them.
      def run_all(map, entries)
        client
        publisher
        progress.start("Checking", entries.length)
        Pool.run(entries, size: jobs, work: ->((key, raw)) { republish(map, key, raw) },
                          started: ->((key, _)) { progress.started(key) },
                          finished: ->(done) { progress.finished(done) }) do |_, result|
          print_result(result)
        end
      ensure
        progress.finish
      end

      # One document failing does not stop the rest, the same as a shell loop
      # without `|| break`.
      def republish(map, key, raw)
        entry = Manifest::Entry.from(raw)
        path = File.expand_path(key, map.dir)
        return Result.new(key, :orphaned, nil, nil, [], nil) unless File.file?(path)

        target = target_for(entry)
        warnings = []
        outcome = publish(path, entry, target, map, warnings)
        Result.new(key, outcome.action, outcome, target, warnings, nil)
      rescue Error => e
        Result.new(key, :failed, nil, nil, [], e.message)
      end

      def print_result(result)
        case result.action
        when :orphaned then stderr.puts "Skipped #{result.key}: no source file. Its Notion page is still live."
        when :failed then stderr.puts "Failed #{result.key}: #{result.message}"
        else report(result.key, result.outcome, result.target, result.warnings)
        end
      end

      def publish(path, entry, target, map, warnings)
        document = Document.load(path)
        settings = settings_for(path)
        icon = document.icon || settings.icon
        cover = document.cover || settings.cover
        Decoration.check!(icon, :icon) if icon
        Decoration.check!(cover, :cover) if cover

        publisher.republish(document, entry: entry, target: target, manifest: map, warnings: warnings,
                                      upload: options[:upload] != false, icon: icon, cover: cover,
                                      force: options[:force] == true,
                                      force_properties: options[:force_properties] == true)
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
