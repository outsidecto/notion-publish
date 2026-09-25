# frozen_string_literal: true

require_relative "client"
require_relative "errors"
require_relative "reference"
require_relative "sharing"
require_relative "target"

module NotionPublish
  # Turns --parent and --database into a Target.
  class Resolver
    class Unreachable < Error; end
    class Ambiguous < Error; end
    class NotNamed < Error; end
    class WrongKind < Error; end

    def initialize(client)
      @client = client
    end

    # --parent takes an ID, a URL, or a database name. Nothing else has to be
    # said: an ID and a URL are recognisable by shape, and anything else is a
    # name. A user cannot tell a page ID from a database ID by looking at it --
    # both are /p/<hex> -- so making them declare the type would be asking for
    # a guess.
    def resolve(input)
      if Reference.reference?(input)
        resolve_reference(input)
      else
        resolve_database_name(input)
      end
    end

    # Identify first, fetch second. A page is also a block, so /v1/blocks says
    # what an ID names in one call and hands back the title with it. That beats
    # probing typed endpoints in turn, which took up to three calls and had to
    # treat /v1/databases' 400 ("is a page, not a database") as a miss.
    def resolve_reference(input)
      ref = Reference.parse(input)
      target = identify(ref.uuid)
      return target if target

      raise Unreachable, Sharing.unreachable(
        id: ref.uuid,
        title: ref.slug_title,
        connection_name: @client.connection_name
      )
    end

    # Notion's search is fuzzy and relevance-ranked, so a single hit does not
    # mean an exact match: querying "a" returns three of thirteen data sources.
    # Publishing into a database the user did not name is silent and annoying to
    # undo, so only an exact title match is accepted.
    def resolve_database_name(name)
      candidates = search_data_sources(name)
      exact = candidates.select { |c| c[:title].casecmp?(name.strip) }

      case exact.length
      when 1 then to_data_source_target(exact.first)
      when 0 then raise NotNamed, no_exact_match_message(name, candidates)
      else raise Ambiguous, ambiguous_message(name, exact)
      end
    end

    private

    def identify(uuid)
      block = fetch_block(uuid)

      case block && block["type"]
      when "child_page"
        Target.new(kind: :page, id: uuid, title: block.dig("child_page", "title"),
                   database_id: nil, inline: false)
      when "child_database"
        database_target(uuid)
      when nil
        # Data sources are not blocks, so a 404 here means either a data source
        # or something we cannot reach. Only the typed call tells them apart.
        data_source_target(uuid)
      else
        raise WrongKind, "#{uuid} is a #{block['type'].tr('_', ' ')} block, not a page or database."
      end
    end

    def fetch_block(uuid)
      @client.get("/v1/blocks/#{uuid}")
    rescue ApiError => e
      raise unless e.not_found?

      nil
    end

    # A database is a container; the schema and the rows live on its data
    # sources. One source resolves cleanly. Two or more is genuinely ambiguous
    # and Notion itself rejects a bare database parent in that case, so we stop
    # and make the user choose rather than guessing.
    def database_target(uuid)
      body = @client.get("/v1/databases/#{uuid}")
      sources = body["data_sources"] || []
      db_title = plain_title(body["title"])

      case sources.length
      when 1
        Target.new(
          kind: :data_source,
          id: sources.first["id"],
          title: sources.first["name"].to_s.empty? ? db_title : sources.first["name"],
          database_id: body["id"],
          inline: body["is_inline"] == true
        )
      when 0
        raise Unreachable, "Database #{db_title.inspect} (#{uuid}) has no data sources."
      else
        raise Ambiguous, multi_source_message(db_title, uuid, sources)
      end
    end

    def data_source_target(uuid)
      body = @client.get("/v1/data_sources/#{uuid}")
      Target.new(
        kind: :data_source,
        id: body["id"],
        title: plain_title(body["title"]),
        database_id: body.dig("parent", "database_id"),
        # Only the database object carries is_inline. A data source whose
        # parent is a block_id is not necessarily inline: a full-page database
        # can have a block_id parent and is_inline false.
        inline: nil
      )
    rescue ApiError => e
      raise unless e.not_found?

      nil
    end

    # Every data source the search returns, across pages. Search ranks by
    # relevance, so an exact match is not guaranteed to be on the first page.
    def search_data_sources(name)
      search_results(name.to_s.strip).map do |result|
        {
          id: result["id"],
          title: plain_title(result["title"]).to_s,
          database_id: result.dig("parent", "database_id"),
          inline: nil
        }
      end
    end

    def search_results(query)
      results = []
      cursor = nil
      loop do
        body = @client.post("/v1/search", {
          "query" => query, "page_size" => Client::PAGE_SIZE, "start_cursor" => cursor,
          "filter" => { "property" => "object", "value" => "data_source" }
        }.compact)
        results.concat(body["results"] || [])
        cursor = body["next_cursor"]
        break unless body["has_more"] && cursor
      end
      results
    end

    def to_data_source_target(hit)
      Target.new(
        kind: :data_source,
        id: hit[:id],
        title: hit[:title],
        database_id: hit[:database_id],
        inline: hit[:inline]
      )
    end

    def plain_title(rich_text)
      return nil unless rich_text.is_a?(Array)

      rich_text.map { |chunk| chunk["plain_text"] }.join
    end

    def no_exact_match_message(name, candidates)
      lines = ["No database is named #{name.inspect}.", ""]
      if candidates.empty?
        lines << "Nothing similar is shared with the #{@client.connection_name.inspect} connection."
        lines << Sharing.instructions(nil)
      else
        lines << "Similar names that are shared with this connection:"
        candidates.first(10).each do |c|
          shown = c[:title].empty? ? "(untitled)" : c[:title]
          lines << "  #{shown}  --parent #{c[:id]}"
        end
        lines << ""
        lines << "Names must match exactly. Use --parent with an ID to be unambiguous."
      end
      lines.join("\n")
    end

    def ambiguous_message(name, matches)
      lines = ["More than one database is named #{name.inspect}:", ""]
      matches.each { |m| lines << "  --parent #{m[:id]}" }
      lines << ""
      lines << "Use --parent with the ID you want."
      lines.join("\n")
    end

    def multi_source_message(db_title, uuid, sources)
      lines = ["Database #{db_title.inspect} (#{uuid}) has #{sources.length} data sources:", ""]
      sources.each do |s|
        name = s["name"].to_s.empty? ? "(untitled)" : s["name"]
        lines << "  #{name}  --parent #{s['id']}"
      end
      lines << ""
      lines << "Point --parent at one of them."
      lines.join("\n")
    end
  end
end
