# frozen_string_literal: true

require "date"
require "json"
require "time"

require_relative "errors"

module NotionPublish
  # The requested property values, before the schema has been consulted.
  #
  # Every value is held as an array of strings. Repeating --property with the
  # same name accumulates; whether that is legal depends on the property's type,
  # which Schema decides later.
  class PropertySet
    include Enumerable

    FRONT_MATTER = "front matter"

    def self.parse_pair(pair)
      name, separator, value = pair.to_s.partition("=")
      raise Error, pair_message(pair) if separator.empty? || name.strip.empty?

      [name.strip, value]
    end

    def self.pair_message(pair)
      <<~MSG.strip
        Cannot read #{pair.to_s.inspect} as a property.

        Use --property 'Name=Value'. Repeat it to give a multi-select or people
        property more than one value:

          --property 'Function=Operations' --property 'Function=Legal'
      MSG
    end

    # Layered lowest to highest: front matter, then --properties-json, then
    # --property. Each layer replaces a name outright rather than adding to it,
    # so overriding one property never drags the old values along.
    def self.build(front_matter: nil, json: nil, pairs: [])
      set = new
      set.merge_hash(front_matter, source: FRONT_MATTER)
      set.merge_hash(parse_json(json), source: "--properties-json") if json
      set.merge_pairs(pairs)
      set
    end

    def self.parse_json(json)
      parsed = JSON.parse(json.to_s)
      raise Error, "--properties-json must be a JSON object, got #{parsed.class}." unless parsed.is_a?(Hash)

      parsed
    rescue JSON::ParserError => e
      raise Error, "Could not parse --properties-json: #{e.message}"
    end

    def initialize
      @values = {}
      @explicit = []
    end

    def merge_hash(hash, source:)
      return self if hash.nil? || hash.empty?
      raise Error, "#{source} properties must be a mapping." unless hash.is_a?(Hash)

      hash.each do |name, value|
        @values[name.to_s] = normalise(value)
        @explicit << name.to_s if source != FRONT_MATTER
      end
      self
    end

    # Properties named on the command line were asked for by this invocation;
    # properties from front matter belong to the document. That matters when a
    # destination cannot hold them: an explicit one is an error, a document one
    # is skipped with a warning.
    def explicit?(name) = @explicit.include?(name.to_s)

    def merge_pairs(pairs)
      seen = {}
      Array(pairs).each do |pair|
        name, value = self.class.parse_pair(pair)
        # First --property for a name replaces any lower layer; later ones add.
        @values[name] = seen[name] ? @values[name] + [value] : [value]
        seen[name] = true
        @explicit << name
      end
      self
    end

    def each(&) = @values.each(&)
    def empty? = @values.empty?
    def names = @values.keys
    def [](name) = @values[name]

    private

    def normalise(value)
      case value
      when nil then [""]
      when Array then value.map { |v| stringify(v) }
      else [stringify(value)]
      end
    end

    def stringify(value)
      case value
      when true then "true"
      when false then "false"
      when Date, Time then value.iso8601
      else value.to_s
      end
    end
  end
end
