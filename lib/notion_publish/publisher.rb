# frozen_string_literal: true

require "digest"
require "json"
require "time"

require_relative "decoration"
require_relative "errors"
require_relative "fixups"
require_relative "links"
require_relative "media"
require_relative "page_map"
require_relative "property_set"
require_relative "schema"
require_relative "uploader"
require_relative "users"

module NotionPublish
  # Creates or updates a Notion page from a Document.
  #
  # Uses POST /v1/pages with the `markdown` body parameter for a new page and
  # PATCH /v1/pages/:id/markdown with `replace_content` for an existing one, so
  # Notion does the Markdown-to-block conversion in both directions. Updating in
  # place keeps the page's URL, which is what makes the identity map worth
  # committing.
  class Publisher
    # What a run did, so the caller can report it and a script can branch on it.
    Outcome = Data.define(:action, :page, :entry, :detail) do
      def blocked? = action == :blocked
      def url = page && page["url"]
      def id = page && page["id"]
    end

    # Everything one publish needs, gathered once so the steps below do not
    # pass a dozen arguments between them. +title+ is already resolved.
    Job = Data.define(:document, :target, :map, :properties, :title, :title_given,
                      :warnings, :upload, :keep_h1, :icon, :cover) do
      def source = File.expand_path(document.path)
      def base_dir = File.dirname(source)
    end

    # The Markdown to send, and the local images it stands in for.
    Body = Data.define(:markdown, :media, :uploads)

    def initialize(client)
      @client = client
    end

    def publish(document, target:, map: nil, properties: PropertySet.new, title: nil,
                title_given: false, warnings: [], upload: true, keep_h1: false,
                icon: nil, cover: nil, force: false, force_properties: false)
      job = Job.new(document: document, target: target, map: map, properties: properties,
                    title: title || document.title, title_given: title_given, warnings: warnings,
                    upload: upload, keep_h1: keep_h1, icon: icon, cover: cover)
      source_hash = Digest::SHA256.hexdigest(File.binread(job.source))
      existing = live_entry(job)

      return write(job, existing, source_hash) if existing.nil? || force

      republish(job, existing, source_hash, force_properties)
    end

    def scan_media(document)
      Media.scan(document.body, base_dir: File.dirname(File.expand_path(document.path)))
    end

    def schema_for(target) = Schema.for(@client, target)

    # An explicit --title wins over a property of the same name. Otherwise the
    # derived title only fills in when the properties did not set one.
    def build_properties(schema, set, title, title_given, warnings = [])
      users = Users.new(@client)
      built = {}

      set.each do |name, values|
        # A page parent holds nothing but a title. Front matter written for a
        # database should not stop the document being published under a page,
        # so it is skipped and reported; an explicit flag still fails.
        if schema.page? && !name.casecmp?("title") && !set.explicit?(name)
          warnings << "Skipped #{name.inspect}: a page parent has no properties."
          next
        end

        key, payload = schema.build(name, values, users: users)
        built[key] = payload
      end

      title_key = schema.title_key
      if title_given || !built.key?(title_key)
        built[title_key] = { "title" => [{ "type" => "text", "text" => { "content" => title.to_s } }] }
      end

      built
    end

    private

    # The recorded entry for this document, unless its page has gone. An entry
    # pointing at a page that no longer exists is stale rather than fatal:
    # forget it and publish afresh.
    def live_entry(job)
      entry = job.map&.entry(job.source)
      return nil unless entry

      @client.get("/v1/pages/#{entry.id}")
      entry
    rescue ApiError => e
      raise unless e.not_found?

      job.warnings << "#{entry.url} is gone from Notion. Publishing a new page and forgetting the old entry."
      job.map.forget(job.source)
      nil
    end

    # The page exists and --force was not given. The body and the properties
    # are compared separately, because reworking only the properties should
    # not mean rewriting every block on the page.
    def republish(job, existing, source_hash, force_properties)
      same_body = existing.source_sha256 == source_hash
      same_properties = !force_properties && properties_unchanged?(job, existing)
      return unchanged(existing) if same_body && same_properties

      blocker = drift(existing)
      return Outcome.new(action: :blocked, page: nil, entry: existing, detail: blocker) if blocker
      return properties_only(job, existing, source_hash) if same_body

      write(job, existing, source_hash)
    end

    def unchanged(entry)
      Outcome.new(action: :unchanged, page: { "url" => entry.url, "id" => entry.id }, entry: entry, detail: nil)
    end

    # A hash of what this run would set, so a reworked set of properties is
    # itself a change worth publishing. Names and values, canonicalised, without
    # storing either in the map.
    def digest(built) = Digest::SHA256.hexdigest(JSON.generate(built.sort.to_h))

    def properties_unchanged?(job, entry)
      # An entry written before this hash existed, or by `adopt`, cannot prove
      # its properties match. Apply them once; that records the digest and every
      # later run can answer properly.
      return false unless entry.properties_sha256

      built = build_properties(schema_for(job.target), job.properties, job.title, job.title_given)
      digest(built) == entry.properties_sha256
    rescue Error
      false
    end

    # Same body, different properties: patch the properties and leave the blocks
    # alone. Cheaper, and it does not disturb images or block ids.
    def properties_only(job, existing, source_hash)
      schema = schema_for(job.target)
      desired = build_properties(schema, job.properties, job.title, job.title_given, job.warnings)
      page = update_properties(job, existing, desired.merge(clearances(schema, existing, desired)))
      record(job, page, source_hash, desired)
      Outcome.new(action: :properties, page: page, entry: job.map&.entry(job.source), detail: nil)
    end

    # Compare Notion's own output against Notion's own output: a round trip is
    # not byte-stable, so the sent form would never match a later read.
    def drift(entry)
      return nil unless entry.notion_sha256
      return nil if Digest::SHA256.hexdigest(read_markdown(entry.id)) == entry.notion_sha256

      <<~MSG.strip
        #{entry.url} has changed in Notion since it was published.

        Republishing replaces the page body and would discard that change. Use
        --force to overwrite it anyway.

        (Every page reporting this at once usually means Notion changed how it
        renders Markdown, not that anybody edited them.)
      MSG
    end

    def read_markdown(page_id) = @client.get("/v1/pages/#{page_id}/markdown")["markdown"].to_s

    def write(job, existing, source_hash)
      body = prepare_body(job)
      schema = schema_for(job.target)
      desired = build_properties(schema, job.properties, job.title, job.title_given, job.warnings)

      page = if existing
               replace_body(existing, body.markdown)
               update_properties(job, existing, desired.merge(clearances(schema, existing, desired)))
             else
               create(job, body.markdown, desired)
             end

      place_images(page["id"], body.media, body.uploads, job.warnings) unless body.uploads.empty?
      record(job, page, source_hash, desired)
      Outcome.new(action: existing ? :updated : :created, page: page, entry: job.map&.entry(job.source), detail: nil)
    end

    # Fixes, link rewriting, and image uploads. Uploads happen here, before any
    # page is touched, so a missing or oversized file fails cleanly.
    def prepare_body(job)
      prepared = prepare(job)
      media = scan_media(prepared)
      note_inline(media, job.warnings)
      return Body.new(markdown: prepared.body, media: media, uploads: {}) unless media.any?

      unless job.upload
        note_skipped_uploads(media, job.warnings)
        return Body.new(markdown: prepared.body, media: media, uploads: {})
      end

      Body.new(markdown: media.body_with_sentinels, media: media, uploads: upload_all(media))
    end

    # Declarative, over the properties this tool set last time. A property it
    # never managed belongs to somebody else and is left alone.
    def clearances(schema, existing, desired)
      (existing.properties - desired.keys).each_with_object({}) do |name, cleared|
        key, payload = schema.build(name, [""])
        cleared[key] = payload
      rescue Error
        # The property no longer exists on the destination; nothing to clear.
        nil
      end
    end

    def create(job, markdown, properties)
      payload = { "parent" => job.target.parent_param, "markdown" => markdown, "properties" => properties }
      @client.post("/v1/pages", payload.merge(decoration(job)))
    end

    def update_properties(job, entry, properties)
      @client.patch("/v1/pages/#{entry.id}", { "properties" => properties }.merge(decoration(job)))
    end

    def decoration(job)
      out = {}
      out["icon"] = Decoration.icon(job.icon, client: @client) if job.icon
      out["cover"] = Decoration.cover(job.cover, client: @client) if job.cover
      out
    end

    def replace_body(entry, markdown)
      @client.patch("/v1/pages/#{entry.id}/markdown",
                    { "type" => "replace_content", "replace_content" => { "new_str" => markdown } })
    rescue ApiError => e
      raise unless e.status == 400 && e.notion_message.to_s.match?(/delet/i)

      raise Error, <<~MSG.strip
        #{entry.url} contains a child page or database, which replacing the body
        would delete. notion-publish will not do that silently.

        Move the child out of the page, or delete the page and publish afresh.
      MSG
    end

    def record(job, page, source_hash, desired)
      return unless job.map

      job.map.workspace_id = @client.me.dig("bot", "workspace_id") || @client.me["id"]
      job.map.record(job.source, PageMap::Entry.new(
                                   id: page["id"], url: page["url"],
                                   parent: { "type" => job.target.page? ? "page_id" : "data_source_id",
                                             "id" => job.target.id, "name" => job.target.title },
                                   properties: desired.keys.sort,
                                   source_sha256: source_hash,
                                   properties_sha256: digest(desired),
                                   notion_sha256: Digest::SHA256.hexdigest(read_markdown(page["id"])),
                                   published_at: Time.now.utc.iso8601
                                 ))
    end

    def prepare(job)
      body = Fixups.apply(job.document.body)
      body = Fixups.strip_leading_h1(body) unless job.keep_h1
      body = rewrite_links(job, body) if job.map
      job.document.with_body(body)
    end

    def rewrite_links(job, body)
      links = Links.new(registry: job.map, base_dir: job.base_dir)
      rewritten = links.rewrite(body)
      links.unresolved.uniq.each do |target|
        job.warnings << "#{target} is not published yet, so that link will point at #{Links.mangled(target)}. " \
                        "Run `notion-publish relink` after publishing it."
      end
      rewritten
    end

    def upload_all(media)
      uploader = Uploader.new(@client)
      media.images.to_h { |image| [image.index, uploader.upload(media.resolved_path(image))] }
    end

    # Each local image was published as a sentinel paragraph. Find it, insert
    # the real image block after it, then delete the sentinel.
    def place_images(page_id, media, uploads, warnings)
      by_text = @client.get_all("/v1/blocks/#{page_id}/children").to_h { |block| [plain_text(block), block["id"]] }

      media.images.each do |image|
        block_id = by_text[image.sentinel]
        unless block_id
          warnings << "Could not place #{image.path}: its marker was not found on the page."
          next
        end

        @client.patch("/v1/blocks/#{page_id}/children", {
                        "children" => [Uploader.image_block(uploads[image.index], image.alt)],
                        "position" => { "type" => "after_block", "after_block" => { "id" => block_id } }
                      })
        @client.delete("/v1/blocks/#{block_id}")
      end
    end

    def plain_text(block)
      content = block[block["type"]]
      return nil unless content.is_a?(Hash)

      (content["rich_text"] || []).map { |chunk| chunk["plain_text"] }.join
    end

    def note_inline(media, warnings)
      media.inline_paths.uniq.each do |path|
        warnings << "#{path} is an image inside a paragraph. Notion has no inline image, " \
                    "so it is left as written and will not render."
      end
    end

    def note_skipped_uploads(media, warnings)
      media.images.each do |image|
        warnings << "Not uploading #{image.path} (--no-upload). It will publish as a broken image."
      end
    end
  end
end
