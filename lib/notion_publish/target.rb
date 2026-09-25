# frozen_string_literal: true

module NotionPublish
  # Where a document is going to land. Everything the CLI accepts — a page ID, a
  # database ID, a data source ID, a URL, a database name — collapses into one
  # of these before anything is written.
  Target = Data.define(:kind, :id, :title, :database_id, :inline) do
    def page? = kind == :page
    def data_source? = kind == :data_source

    # The `parent` object for POST /v1/pages.
    def parent_param
      case kind
      when :page then { "page_id" => id }
      when :data_source then { "data_source_id" => id }
      else raise ArgumentError, "unknown target kind: #{kind}"
      end
    end

    # +inline+ is a tri-state: true, false, or nil when we resolved through a
    # data source and never fetched the database that would tell us.
    def kind_label
      case kind
      when :page then "page"
      when :data_source then inline == true ? "inline database" : "database"
      end
    end

    def describe
      name = title.nil? || title.empty? ? "(untitled)" : title
      "#{kind_label} #{name.inspect} (#{id})"
    end
  end
end
