# frozen_string_literal: true

module NotionPublish
  # Request logging for -vv and -vvv, written to stderr so it never mixes with
  # --json on stdout.
  #
  # Level 1 is one line per request: method, path, status, and time taken,
  # plus a line for each retry. Level 2 adds request and response bodies,
  # shortened. The token is never logged at any level: it travels only in the
  # Authorization header, and headers are not logged.
  class Log
    BODY_LIMIT = 300

    attr_reader :level

    def initialize(io, level)
      @io = io
      @level = level
    end

    def request(method, uri, status, seconds)
      line("#{method} #{uri.request_uri} -> #{status} (#{(seconds * 1000).round} ms)")
    end

    def retrying(status, delay, attempt, max)
      line("  #{status}: retrying in #{delay}s (attempt #{attempt + 1} of #{max})")
    end

    def body(direction, text)
      return unless level >= 2
      return if text.nil? || text.empty?

      line("  #{direction} #{shorten(text)}")
    end

    def note(message) = line(message)

    private

    def line(message) = @io.puts("notion-publish: #{message}")

    def shorten(text)
      flat = text.to_s.gsub(/\s+/, " ")
      flat.length > BODY_LIMIT ? "#{flat[0, BODY_LIMIT]}... (#{flat.length} chars)" : flat
    end
  end
end
