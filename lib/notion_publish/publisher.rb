# frozen_string_literal: true

require "digest"
require "json"
require "time"

require_relative "notion_digest"
require_relative "decoration"
require_relative "errors"
require_relative "fixups"
require_relative "links"
require_relative "media"
require_relative "page_map"
require_relative "property_set"
require_relative "schema"
require_relative "status"
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
    #
    # +preserve+ lists properties this run must neither set nor clear: on a
    # republish, the ones an earlier run set from flags, whose values were
    # never recorded.
    Job = Data.define(:document, :target, :map, :properties, :title, :title_given,
                      :warnings, :upload, :keep_h1, :icon, :cover, :preserve, :republish) do
      def source = File.expand_path(document.path)
      def base_dir = File.dirname(source)
    end

    # Built property payloads, split by where the values came from: the
    # document (front matter, the derived title, a recorded --title) or flags.
    Properties = Data.define(:document, :flags) do
      def all = document.merge(flags)
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
                    upload: upload, keep_h1: keep_h1, icon: icon, cover: cover, preserve: [], republish: false)
      run(job, force: force, force_properties: force_properties)
    end

    # Publishes a document again from what its entry recorded: front matter,
    # plus any --title and --keep-h1 the last single-file publish was given.
    # Properties that were set from flags are left as they are.
    def republish(document, entry:, target:, map:, warnings: [], upload: true, icon: nil, cover: nil,
                  force: false, force_properties: false)
      job = Job.new(document: document, target: target, map: map,
                    properties: PropertySet.build(front_matter: document.properties),
                    title: entry.title_override || document.title, title_given: !entry.title_override.nil?,
                    warnings: warnings, upload: upload, keep_h1: entry.keep_h1 == true, icon: icon, cover: cover,
                    preserve: entry.flag_properties || [], republish: true)

      if (reason = unrecorded_flags(job, entry))
        return Outcome.new(action: :skipped, page: { "url" => entry.url, "id" => entry.id }, entry: entry,
                           detail: reason)
      end

      run(job, force: force, force_properties: force_properties)
    end

    def scan_media(document)
      Media.scan(document.body, base_dir: File.dirname(File.expand_path(document.path)))
    end

    # Cached per destination, since a republish reads the same schema for
    # every document in it.
    def schema_for(target)
      (@schemas ||= {})[target.id] ||= Schema.for(@client, target)
    end

    # Every property payload this run would set.
    def build_properties(schema, set, title, title_given, warnings = [])
      split_properties(schema, set, title, title_given, warnings).all
    end

    # An explicit --title wins over a property of the same name. Otherwise the
    # derived title only fills in when the properties did not set one. Keys in
    # +skip+ are left out entirely.
    def split_properties(schema, set, title, title_given, warnings = [], skip: [])
      users = Users.new(@client)
      document = {}
      flags = {}

      set.each do |name, values|
        # A page parent holds nothing but a title. Front matter written for a
        # database should not stop the document being published under a page,
        # so it is skipped and reported; an explicit flag still fails.
        if schema.page? && !name.casecmp?("title") && !set.explicit?(name)
          warnings << "Skipped #{name.inspect}: a page parent has no properties."
          next
        end

        key, payload = schema.build(name, values, users: users)
        next if skip.include?(key)

        (set.explicit?(name) ? flags : document)[key] = payload
      end

      add_title(document, flags, schema.title_key, title: title, title_given: title_given, skip: skip)
      Properties.new(document: document.except(*flags.keys), flags: flags)
    end

    private

    def add_title(document, flags, key, title:, title_given:, skip:)
      payload = { "title" => [{ "type" => "text", "text" => { "content" => title.to_s } }] }
      if title_given
        flags.delete(key)
        document[key] = payload
      elsif !document.key?(key) && !flags.key?(key) && !skip.include?(key)
        document[key] = payload
      end
    end

    def run(job, force:, force_properties:)
      source_hash = Digest::SHA256.hexdigest(File.binread(job.source))
      existing = live_entry(job)

      return write(job, existing, source_hash) if existing.nil? || force

      update_existing(job, existing, source_hash, force_properties)
    end

    # An entry written before flag-set properties were recorded cannot say
    # which of its properties came from flags. Republishing it from front
    # matter alone would clear those, so it is only safe when front matter
    # still produces exactly what was set last time.
    def unrecorded_flags(job, entry)
      return nil unless entry.flag_properties.nil?
      return nil if entry.properties.empty?

      props = split_properties(schema_for(job.target), job.properties, job.title, job.title_given)
      return nil if entry.properties_sha256 && digest(props.document) == entry.properties_sha256

      <<~MSG.strip
        #{entry.url} was published before notion-publish recorded which properties
        came from flags, and its front matter no longer produces the properties it
        was given. Republishing it could clear a property that was set with
        --property or change a title set with --title.

        Publish this file on its own once, with whatever flags it needs. After
        that, republish handles it.
      MSG
    end

    # The recorded entry for this document, unless its page has gone. An entry
    # pointing at a page that no longer exists, or that someone moved to the
    # trash, is stale rather than fatal: forget it and publish afresh.
    def live_entry(job)
      entry = job.map&.entry(job.source)
      return nil unless entry
      return entry unless Status.trashed?(@client.get("/v1/pages/#{entry.id}"))

      forget(job, entry, "is in Notion's trash")
    rescue ApiError => e
      raise unless e.not_found?

      forget(job, entry, "is gone from Notion")
    end

    def forget(job, entry, why)
      job.warnings << "#{entry.url} #{why}. Publishing a new page and forgetting the old entry."
      job.map.forget(job.source)
      nil
    end

    # The page exists and --force was not given. The body and the properties
    # are compared separately, because reworking only the properties should
    # not mean rewriting every block on the page.
    def update_existing(job, existing, source_hash, force_properties)
      same_body = existing.source_sha256 == source_hash
      same_properties = !force_properties && properties_unchanged?(job, existing)

      # Checked even when there is nothing to send: an edit made only in
      # Notion is exactly the divergence this tool exists to report.
      blocker = drift(existing)
      return Outcome.new(action: :blocked, page: nil, entry: existing, detail: blocker) if blocker
      return unchanged(existing) if same_body && same_properties
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

    # The document's properties and the flag-set ones are hashed separately,
    # so a republish, which leaves flag-set properties alone, can still tell
    # whether anything it owns has changed.
    def properties_unchanged?(job, entry)
      # An entry written before this hash existed, or by `adopt`, cannot prove
      # its properties match. Apply them once; that records the digest and every
      # later run can answer properly.
      return false unless entry.properties_sha256

      props = split_properties(schema_for(job.target), job.properties, job.title, job.title_given,
                               skip: job.preserve)
      return false unless digest(props.document) == entry.properties_sha256

      job.republish || flags_digest(props) == entry.flag_properties_sha256
    rescue Error
      false
    end

    def flags_digest(props) = props.flags.empty? ? nil : digest(props.flags)

    def split_for(job, schema)
      split_properties(schema, job.properties, job.title, job.title_given, job.warnings, skip: job.preserve)
    end

    # Same body, different properties: patch the properties and leave the blocks
    # alone. Cheaper, and it does not disturb images or block ids.
    def properties_only(job, existing, source_hash)
      schema = schema_for(job.target)
      props = split_for(job, schema)
      page = update_properties(job, existing, props.all.merge(clearances(schema, existing, props.all, job.preserve)))
      record(job, page, source_hash, props, existing)
      Outcome.new(action: :properties, page: page, entry: job.map&.entry(job.source), detail: nil)
    end

    # Compare Notion's own output against Notion's own output: a round trip is
    # not byte-stable, so the sent form would never match a later read.
    def drift(entry)
      return nil unless entry.notion_sha256
      return nil if NotionDigest.of(read_markdown(entry.id)) == entry.notion_sha256

      <<~MSG.strip
        #{entry.url} has changed in Notion since it was published.

        Publishing replaces the page body and would discard that change. Move
        the change into the Markdown if it should stay, then publish with
        --force, which also puts back the Markdown's version when it should not.

        (Every page reporting this at once usually means Notion changed how it
        renders Markdown, not that anybody edited them.)
      MSG
    end

    def read_markdown(page_id) = @client.get("/v1/pages/#{page_id}/markdown")["markdown"].to_s

    def write(job, existing, source_hash)
      body = prepare_body(job)
      schema = schema_for(job.target)
      props = split_for(job, schema)
      desired = props.all

      page = if existing
               replace_body(existing, body.markdown)
               update_properties(job, existing, desired.merge(clearances(schema, existing, desired, job.preserve)))
             else
               note_lost_flags(job)
               create(job, body.markdown, desired)
             end

      place_images(page["id"], body.media, body.uploads, job.warnings) unless body.uploads.empty?
      record(job, page, source_hash, props, existing)
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

    # A republished page that had to be recreated starts without the
    # properties an earlier run set from flags, and republish cannot restore
    # them because their values were never recorded.
    def note_lost_flags(job)
      return if job.preserve.empty?

      job.warnings << "The new page does not have #{job.preserve.join(', ')}, which were set with flags. " \
                      "Publish #{job.document.path} on its own with those flags to restore them."
    end

    # Declarative, over the properties this tool set last time. A property it
    # never managed belongs to somebody else and is left alone, and so is one
    # being preserved.
    def clearances(schema, existing, desired, preserve)
      (existing.properties - desired.keys - preserve).each_with_object({}) do |name, cleared|
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

    def record(job, page, source_hash, props, existing)
      return unless job.map

      job.map.workspace_id = @client.me.dig("bot", "workspace_id") || @client.me["id"]
      job.map.record(job.source, entry_for(job, page, source_hash, props, existing))
    end

    def entry_for(job, page, source_hash, props, existing)
      flag_names, flag_digest = recorded_flags(job, props, existing)
      PageMap::Entry.new(
        id: page["id"], url: page["url"],
        parent: { "type" => job.target.page? ? "page_id" : "data_source_id",
                  "id" => job.target.id, "name" => job.target.title },
        properties: (props.document.keys + flag_names).uniq.sort,
        flag_properties: flag_names,
        title_override: job.title_given ? job.title.to_s : nil,
        keep_h1: job.keep_h1 || nil,
        source_sha256: source_hash,
        properties_sha256: digest(props.document),
        flag_properties_sha256: flag_digest,
        notion_sha256: NotionDigest.of(read_markdown(page["id"])),
        published_at: Time.now.utc.iso8601
      )
    end

    # A republish of an existing page carries the flag-set properties over
    # untouched. Anything else records what this run's flags set.
    def recorded_flags(job, props, existing)
      return [existing.flag_properties || [], existing.flag_properties_sha256] if job.republish && existing

      [props.flags.keys.sort, flags_digest(props)]
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
      # Sentinel text => [its block id, the block it sits in]. The image has to
      # be appended to that parent: Notion refuses an after_block position
      # under any other block, including the page itself.
      found = blocks_under(page_id).to_h { |block, parent| [plain_text(block), [block["id"], parent]] }

      media.images.each do |image|
        block_id, parent_id = found[image.sentinel]
        unless block_id
          warnings << "Could not place #{image.path}: its marker was not found on the page."
          next
        end

        @client.patch("/v1/blocks/#{parent_id}/children", {
                        "children" => [Uploader.image_block(uploads[image.index], image.alt)],
                        "position" => { "type" => "after_block", "after_block" => { "id" => block_id } }
                      })
        @client.delete("/v1/blocks/#{block_id}")
      end
    end

    # Every block on the page as [block, parent id], including blocks nested
    # in list items and toggles, since an image written under a list item is
    # placed there. Child pages and databases are separate documents and are
    # not entered.
    def blocks_under(parent_id)
      @client.get_all("/v1/blocks/#{parent_id}/children").flat_map do |block|
        nested = block["has_children"] && !%w[child_page child_database].include?(block["type"])
        nested ? [[block, parent_id], *blocks_under(block["id"])] : [[block, parent_id]]
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
