# frozen_string_literal: true

require "did_you_mean"

require_relative "errors"
require_relative "reference"

module NotionPublish
  # The property definitions of a publishing target, and the rules for turning
  # command-line strings into Notion property values.
  #
  # Because the schema is fetched anyway, the CLI syntax carries no type or
  # arity information: --property 'Due Date=2026-09-15' is a date because the
  # schema says so, and repeating --property is a list only where the property
  # can hold one.
  class Schema
    # Notion computes these. Writing them is an error, so say so plainly rather
    # than letting the API reject the whole request.
    COMPUTED = %w[created_time created_by last_edited_time last_edited_by formula rollup unique_id].freeze

    # Everything else holds exactly one value.
    MULTI_VALUED = %w[multi_select people relation].freeze

    OPTION_TYPES = %w[select status multi_select].freeze

    attr_reader :properties

    def self.for(client, target)
      return new({}, page: true) if target.page?

      body = client.get("/v1/data_sources/#{target.id}")
      new(body["properties"] || {})
    end

    def initialize(properties, page: false)
      @properties = properties
      @page = page
    end

    def page? = @page

    def title_key
      return "title" if page?

      key, = properties.find { |_, definition| definition["type"] == "title" }
      key or raise Error, "This data source has no title property."
    end

    def names = properties.keys

    # Property names are matched case-insensitively, because nobody remembers
    # whether it is "Due Date" or "Due date".
    def lookup(name)
      wanted = name.to_s.strip
      properties.find { |key, _| key.casecmp?(wanted) }
    end

    def type_of(name)
      _, definition = lookup(name)
      definition && definition["type"]
    end

    def multi_valued?(name) = MULTI_VALUED.include?(type_of(name))

    # Returns [notion_key, value_payload] ready to drop into a page's
    # properties. +values+ is always an array; arity is checked here.
    def build(name, values, users: nil)
      if page?
        raise Error, page_parent_message(name) unless name.casecmp?("title")

        return ["title", text_payload("title", values.first.to_s)]
      end

      key, definition = lookup(name)
      raise Error, unknown_property_message(name) unless key

      type = definition["type"]
      raise Error, computed_message(key, type) if COMPUTED.include?(type)

      return [key, empty_payload(type)] if cleared?(values)
      raise Error, arity_message(key, type, values) if values.length > 1 && !MULTI_VALUED.include?(type)

      [key, payload(key, definition, type, values, users)]
    end

    private

    def cleared?(values) = values.length == 1 && values.first.to_s.empty?

    # One branch per property type Notion defines; splitting it would only scatter the table.
    def payload(key, definition, type, values, users) # rubocop:disable Metrics/CyclomaticComplexity
      case type
      when "title", "rich_text" then text_payload(type, values.first.to_s)
      when "select", "status" then { type => { "name" => option!(key, definition, type, values.first) } }
      when "multi_select"
        { "multi_select" => values.map { |v| { "name" => option!(key, definition, type, v) } } }
      when "people" then { "people" => values.map { |v| { "object" => "user", "id" => user!(v, users) } } }
      when "relation" then { "relation" => values.map { |v| { "id" => Reference.parse(v).uuid } } }
      when "date" then { "date" => date_payload(key, values.first) }
      when "checkbox" then { "checkbox" => checkbox!(key, values.first) }
      when "number" then { "number" => number!(key, values.first) }
      when "url", "email", "phone_number" then { type => values.first.to_s }
      when "files"
        raise Error, "#{key} is a files property. notion-publish cannot set file properties yet."
      else
        raise Error, "#{key} is a #{type} property, which notion-publish cannot set."
      end
    end

    def text_payload(type, string)
      { type => [{ "type" => "text", "text" => { "content" => string } }] }
    end

    def empty_payload(type)
      case type
      when "title", "rich_text" then { type => [] }
      when "multi_select" then { "multi_select" => [] }
      when "people" then { "people" => [] }
      when "relation" then { "relation" => [] }
      when "checkbox" then { "checkbox" => false }
      else { type => nil }
      end
    end

    # Notion *creates* an unrecognised select option instead of rejecting it, so
    # a typo would silently grow the schema. Match against the existing options
    # and return their canonical spelling.
    def option!(key, definition, type, value)
      wanted = value.to_s.strip
      options = definition.dig(type, "options") || []
      match = options.find { |o| o["name"].casecmp?(wanted) }
      return match["name"] if match

      raise Error, unknown_option_message(key, wanted, options.map { |o| o["name"] })
    end

    # A people value may be a user ID or a name, which needs the workspace's
    # user list to resolve. That list is fetched lazily, only when needed.
    def user!(value, users)
      candidate = value.to_s.strip
      return candidate if candidate.match?(Reference::BARE_ID)
      raise Error, "Cannot resolve #{candidate.inspect} to a user." unless users

      users.resolve(candidate)
    end

    def date_payload(key, value)
      start, finish = value.to_s.split("..", 2).map(&:strip)
      raise Error, "#{key} needs a date, got an empty value." if start.to_s.empty?

      payload = { "start" => start }
      payload["end"] = finish if finish && !finish.empty?
      payload
    end

    def checkbox!(key, value)
      case value.to_s.strip.downcase
      when "true", "yes", "y", "1", "checked" then true
      when "false", "no", "n", "0", "unchecked" then false
      else raise Error, "#{key} is a checkbox. Use true or false, not #{value.to_s.inspect}."
      end
    end

    def number!(key, value)
      string = value.to_s.strip
      return Integer(string) if string.match?(/\A-?\d+\z/)

      Float(string)
    rescue ArgumentError, TypeError
      raise Error, "#{key} is a number. #{value.to_s.inspect} is not one."
    end

    def unknown_property_message(name)
      close = DidYouMean::SpellChecker.new(dictionary: names).correct(name.to_s)
      lines = ["There is no property named #{name.to_s.inspect}."]
      lines << "" << "Did you mean: #{close.join(', ')}" unless close.empty?
      lines << "" << "Run `notion-publish properties` to see the schema."
      lines.join("\n")
    end

    def unknown_option_message(key, value, options)
      <<~MSG.strip
        #{key} has no option named #{value.inspect}.

        Options are: #{options.join(' | ')}

        Notion would create a new option rather than reject this, so
        notion-publish refuses it. Add the option in Notion first.
      MSG
    end

    def computed_message(key, type)
      "#{key} is a #{type} property. Notion computes it and it cannot be set."
    end

    def arity_message(key, type, values)
      "#{key} is a #{type} property and takes one value; you gave #{values.length}: " \
        "#{values.map(&:inspect).join(', ')}"
    end

    def page_parent_message(name)
      "A page parent accepts only a title, so #{name.to_s.inspect} cannot be set. " \
        "Publish into a database to set properties."
    end
  end
end
