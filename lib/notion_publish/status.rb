# frozen_string_literal: true

require "digest"

require_relative "notion_digest"
require_relative "errors"
require_relative "page_map"
require_relative "pool"

module NotionPublish
  # What would happen if you published everything.
  #
  # Answers the question the identity map exists to make answerable: which
  # documents are in sync, which have changed locally, which changed in Notion,
  # and which entries no longer have a source file.
  class Status
    STATES = {
      unchanged: "in sync",
      modified: "changed locally",
      drifted: "changed in Notion",
      diverged: "changed in both",
      missing: "page is gone from Notion",
      trashed: "page is in Notion's trash",
      orphaned: "no source file",
      unpublished: "never published"
    }.freeze

    # States that mean something needs doing to a document the map tracks.
    ACTIONABLE = %i[modified drifted diverged missing trashed orphaned].freeze

    SKIP_DIRS = %w[.git node_modules vendor tmp .bundle].freeze

    Row = Data.define(:source, :state, :url) do
      def actionable? = ACTIONABLE.include?(state)
      def label = STATES[state]
    end

    # Whether a page object is in Notion's trash. Older API versions called
    # this "archived".
    def self.trashed?(page) = page["in_trash"] == true || page["archived"] == true

    def initialize(map, client: nil)
      @map = map
      @client = client
    end

    # Pages are checked a few at a time. +started+ is called with each key as
    # it is picked up and +finished+ with the count done so far, both on the
    # calling thread, so a caller can show progress.
    def rows(dir: nil, check_notion: true, started: nil, finished: nil, jobs: Pool::SIZE)
      @client&.me if check_notion
      tracked = Pool.run(@map.pages.to_a, size: jobs,
                                          work: lambda { |(key, raw)|
                                            tracked_row(key, PageMap::Entry.from(raw), check_notion)
                                          },
                                          started: started && ->((key, _)) { started.call(key) }, finished: finished)
      tracked.sort_by { |r| [ACTIONABLE.index(r.state) || 99, r.source] } + untracked(dir)
    end

    private

    def tracked_row(key, entry, check_notion)
      path = File.expand_path(key, @map.dir)
      return Row.new(source: key, state: :orphaned, url: entry.url) unless File.file?(path)

      local = entry.source_sha256 && entry.source_sha256 != Digest::SHA256.hexdigest(File.binread(path))
      remote = check_notion ? remote_state(entry) : nil
      return Row.new(source: key, state: remote, url: entry.url) if %i[missing trashed].include?(remote)

      Row.new(source: key, state: state_for(local, remote == :drifted), url: entry.url)
    end

    def state_for(local, remote)
      return :diverged if local && remote
      return :modified if local
      return :drifted if remote

      :unchanged
    end

    # :missing, :trashed, :drifted, or nil when the page is as published.
    #
    # Deleting a page in Notion moves it to the trash, and the API still
    # returns a trashed page, Markdown and all. Only the page object says so,
    # which is why it is read for every page, not only for those whose
    # content changed: a page trashed without being edited still matches.
    def remote_state(entry)
      return nil unless @client
      return :trashed if Status.trashed?(@client.get("/v1/pages/#{entry.id}"))
      return :drifted if drifted?(entry)

      nil
    rescue ApiError => e
      raise unless e.not_found?

      :missing
    end

    # Notion's own output on both sides: a round trip is not byte-stable, so the
    # sent form would never match a later read.
    def drifted?(entry)
      return false unless entry.notion_sha256

      markdown = @client.get("/v1/pages/#{entry.id}/markdown")["markdown"].to_s
      NotionDigest.of(markdown) != entry.notion_sha256
    end

    # Markdown files under the map that have never been published. Reported for
    # information; they are not counted as needing action, because plenty of
    # files are deliberately not mirrored.
    def untracked(dir)
      root = dir ? File.expand_path(dir) : @map.dir
      return [] unless File.directory?(root)

      known = @map.pages.keys.map { |k| File.expand_path(k, @map.dir) }
      markdown_under(root).reject { |p| known.include?(p) }
                          .sort
                          .map { |p| Row.new(source: @map.key_for(p), state: :unpublished, url: nil) }
    end

    def markdown_under(root)
      Dir.glob("**/*.md", base: root)
         .reject { |rel| rel.split(File::SEPARATOR).any? { |part| SKIP_DIRS.include?(part) || part.start_with?(".") } }
         .map { |rel| File.join(root, rel) }
    end
  end
end
