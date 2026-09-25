# frozen_string_literal: true

require "digest"

require_relative "command"
require_relative "reporting"
require_relative "../decoration"
require_relative "../document"
require_relative "../publisher"

module NotionPublish
  module Commands
    # Publishes one Markdown file, or with --dry-run says what publishing it
    # would do.
    class Publish < Command
      include Reporting

      # How a dry run shows each kind of property value.
      SUMMARIES = {
        "title" => ->(value) { value.map { |v| v.dig("text", "content") }.join.inspect },
        "rich_text" => ->(value) { value.map { |v| v.dig("text", "content") }.join.inspect },
        "multi_select" => ->(value) { value.map { |v| v["name"] }.inspect },
        "select" => ->(value) { value["name"].inspect },
        "status" => ->(value) { value["name"].inspect },
        "people" => ->(value) { value.map { |v| v["id"] }.inspect },
        "relation" => ->(value) { value.map { |v| v["id"] }.inspect }
      }.freeze

      def call(path)
        document = Document.load(path)
        settings = settings_for(path)
        map = page_map_for(path)
        target = destination(document, settings, map&.entry(File.expand_path(path)))
        icon = options[:icon] || document.icon || settings.icon
        cover = options[:cover] || document.cover || settings.cover
        Decoration.check!(icon, :icon) if icon
        Decoration.check!(cover, :cover) if cover

        return dry_run(path, document, target, map, icon: icon, cover: cover) if options[:dry_run]

        warnings = []
        outcome = publisher.publish(document, target: target, map: map, properties: property_set(document),
                                              warnings: warnings, icon: icon, cover: cover, **publish_flags)
        report(path, outcome, target, warnings)
      end

      private

      def publisher = @publisher ||= Publisher.new(client)

      # A file the map already tracks is updated where its page is, so it needs
      # no destination. One that is given anyway is still used.
      def destination(document, settings, entry)
        named = options[:parent] || options[:database] || document.parent || document.database ||
                settings.parent || settings.database
        return target_for(entry) if entry && !named

        resolve_destination(document, settings)
      end

      def publish_flags
        {
          title: options[:title], title_given: !options[:title].nil?,
          upload: options[:upload] != false, keep_h1: options[:keep_h1] == true,
          force: options[:force] == true, force_properties: options[:force_properties] == true
        }
      end

      # Without --link, a map is used only if one already exists; publishing
      # never starts recording a corpus unasked.
      def page_map_for(path)
        return nil if options[:link] == false

        map = PageMap.locate(path, override: options[:pages_file], reporter: map_reporter)
        return map unless map.created?
        return nil unless options[:link] || options[:pages_file]

        stderr.puts "Creating #{map.path}"
        map
      end

      # A dry run resolves, validates every property against the live schema,
      # and says what a real run would do.
      def dry_run(path, document, target, map, icon:, cover:)
        warnings = []
        built = preview_properties(document, target, warnings)
        media = publisher.scan_media(document)
        check_images(media)

        warnings.each { |w| stderr.puts w }
        stdout.puts "Would #{intended_action(path, map)} #{path} to #{target.describe}"
        stdout.puts "  title: #{(options[:title] || document.title).inspect}"
        built.each { |key, payload| stdout.puts "  #{key}: #{summarise(payload)}" }
        media.images.each { |image| stdout.puts "  upload: #{image.path}" }
        stdout.puts "  icon: #{icon}" if icon
        stdout.puts "  cover: #{cover}" if cover
        CLI::OK
      end

      def preview_properties(document, target, warnings)
        set = property_set(document)
        return {} if set.empty?

        publisher.build_properties(publisher.schema_for(target), set, options[:title] || document.title,
                                   !options[:title].nil?, warnings)
      end

      def check_images(media)
        media.images.each do |image|
          resolved = media.resolved_path(image)
          next if File.file?(resolved)

          raise Error, "No such image: #{image.path} (looked in #{File.dirname(resolved)})"
        end
      end

      def intended_action(path, map)
        entry = map&.entry(File.expand_path(path))
        return "publish" unless entry

        same = entry.source_sha256 == Digest::SHA256.hexdigest(File.binread(File.expand_path(path)))
        same && options[:force] != true ? "leave unchanged" : "update"
      end

      def summarise(payload)
        type, value = payload.first
        SUMMARIES.fetch(type, :inspect.to_proc).call(value)
      end
    end
  end
end
