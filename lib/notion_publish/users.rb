# frozen_string_literal: true

require "did_you_mean"

require_relative "errors"

module NotionPublish
  # Resolves a person's name to a user ID, for people properties. Fetched once,
  # and only when a people property is actually being set by name.
  class Users
    def initialize(client)
      @client = client
    end

    def resolve(name)
      wanted = name.to_s.strip
      matches = all.select { |u| u["name"].to_s.casecmp?(wanted) }

      case matches.length
      when 1 then matches.first["id"]
      when 0 then raise Error, no_match_message(wanted)
      else raise Error, ambiguous_message(wanted, matches)
      end
    end

    private

    def all
      @all ||= @client.get_all("/v1/users")
    end

    def people = all.select { |u| u["type"] == "person" }

    def no_match_message(wanted)
      close = DidYouMean::SpellChecker.new(dictionary: people.map { |u| u["name"] }.compact).correct(wanted)
      lines = ["No workspace user is named #{wanted.inspect}."]
      lines << "" << "Close matches: #{close.join(', ')}" unless close.empty?
      lines << "" << "A user ID works too."
      lines.join("\n")
    end

    def ambiguous_message(wanted, matches)
      lines = ["More than one user is named #{wanted.inspect}:", ""]
      matches.each { |u| lines << "  #{u['id']}  (#{u['type']})" }
      lines << "" << "Use the ID."
      lines.join("\n")
    end
  end
end
