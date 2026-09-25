# frozen_string_literal: true

require_relative "errors"
require_relative "reference"
require_relative "schema"
require_relative "sharing"

module NotionPublish
  # Finds the Notion page that a local file already corresponds to.
  #
  # Two ways to say it. Naming the page is exact. Searching by title is a guess,
  # which is why this is a separate command rather than something publishing
  # does on anyone's behalf.
  class Adopter
    Candidate = Data.define(:id, :url, :title, :last_edited_time, :last_edited_by)

    def initialize(client)
      @client = client
    end

    # The exact form: the caller named the page.
    def by_page(input)
      uuid = Reference.parse(input).uuid
      page = @client.get("/v1/pages/#{uuid}")
      candidate(page)
    rescue ApiError => e
      raise unless e.not_found?

      raise Error, Sharing.unreachable(id: uuid, title: Reference.parse(input).slug_title,
                                       connection_name: @client.connection_name)
    end

    # The guess: every page in the destination whose title matches exactly.
    def by_title(target, title)
      pages = target.page? ? children_of(target.id) : rows_of(target, title)
      pages.select { |page| candidate(page).title.to_s.casecmp?(title.to_s.strip) }
           .map { |page| candidate(page) }
    end

    private

    def rows_of(target, title)
      key = Schema.for(@client, target).title_key
      body = { "filter" => { "property" => key, "title" => { "equals" => title.to_s } }, "page_size" => 25 }
      @client.post("/v1/data_sources/#{target.id}/query", body)["results"] || []
    end

    def children_of(page_id)
      @client.get_all("/v1/blocks/#{page_id}/children")
             .select { |b| b["type"] == "child_page" }
             .map { |b| @client.get("/v1/pages/#{b['id']}") }
    end

    def candidate(page)
      Candidate.new(
        id: page["id"], url: page["url"], title: title_of(page),
        last_edited_time: page["last_edited_time"],
        last_edited_by: user_name(page.dig("last_edited_by", "id"))
      )
    end

    def title_of(page)
      prop = (page["properties"] || {}).values.find { |v| v["type"] == "title" }
      return nil unless prop

      (prop["title"] || []).map { |chunk| chunk["plain_text"] }.join
    end

    def user_name(id)
      return nil unless id

      (@names ||= {})[id] ||= @client.get("/v1/users/#{id}")["name"]
    rescue ApiError
      nil
    end
  end
end
