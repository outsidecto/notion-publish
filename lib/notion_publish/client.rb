# frozen_string_literal: true

require "json"
require "monitor"
require "net/http"
require "uri"

require_relative "errors"
require_relative "log"
require_relative "version"

module NotionPublish
  # A small hand-rolled Notion client.
  #
  # There is no official Ruby SDK, and every community gem on RubyGems predates
  # both the data-source split (2025-09-03) and the markdown endpoints, so
  # wrapping one would mean fighting a client that models an older API. The
  # surface we need is five endpoints, so this is Net::HTTP and no dependencies.
  class Client
    API_ORIGIN = "https://api.notion.com"
    API_VERSION = "2026-03-11"

    # Env vars are checked in this order. NOTION_API_TOKEN is what Notion's own
    # `ntn` CLI reads; NOTION_API_KEY is what its quickstart tells people to set.
    TOKEN_ENV_VARS = %w[NOTION_API_TOKEN NOTION_API_KEY].freeze

    RETRYABLE_STATUSES = [429, 502, 503, 504, 529].freeze
    MAX_ATTEMPTS = 4
    PAGE_SIZE = 100
    USER_AGENT = "notion-publish/#{VERSION} (+https://github.com/outsidecto/notion-publish)".freeze

    attr_reader :api_version

    def self.token_from_env(env = ENV)
      TOKEN_ENV_VARS.each do |name|
        value = env[name]
        return value unless value.nil? || value.strip.empty?
      end
      nil
    end

    # +log+ is a Log, or nil for silence.
    def initialize(token: nil, api_version: API_VERSION, sleeper: method(:sleep), log: nil)
      @token = token || self.class.token_from_env
      raise MissingToken, TOKEN_ENV_VARS if @token.nil? || @token.strip.empty?

      @api_version = api_version
      @sleeper = sleeper
      @log = log
      # Net::HTTP is not safe to share between threads, so each thread that
      # makes requests gets its own kept-alive connection.
      @connections = {}
      @lock = Monitor.new
    end

    def delete(path) = request(Net::HTTP::Delete, path)
    def get(path, query = nil)  = request(Net::HTTP::Get, path, query: query)
    def post(path, body = nil)  = request(Net::HTTP::Post, path, body: body)
    def patch(path, body = nil) = request(Net::HTTP::Patch, path, body: body)

    # Every result of a paginated GET, following next_cursor to the end.
    def get_all(path, query = {})
      results = []
      cursor = nil
      loop do
        page = get(path, query.merge("page_size" => PAGE_SIZE, "start_cursor" => cursor))
        results.concat(page["results"] || [])
        cursor = page["next_cursor"]
        break unless page["has_more"] && cursor
      end
      results
    end

    # Sends file bytes to the upload URL handed back by POST /v1/file_uploads.
    # That endpoint wants multipart/form-data rather than JSON, so it does not
    # go through #request.
    def post_file(url, path:, content_type:)
      uri = URI(url)
      boundary = "notion-publish-#{Time.now.to_i}-#{rand(1 << 32)}"

      req = authorized(Net::HTTP::Post.new(uri))
      req["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
      req.body = multipart(boundary, path, content_type)

      started = monotonic
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 120) do |http|
        http.request(req)
      end
      # The body is file bytes, so describe it rather than print it.
      trace(req, response, monotonic - started, sent: "(#{File.size(path)} bytes of #{content_type})")
      parsed = parse(response)
      return parsed if response.code.to_i.between?(200, 299)

      raise ApiError.new(status: response.code.to_i, body: parsed)
    end

    # Keeps the token out of logs and exception reports.
    def inspect = "#<#{self.class.name} api_version=#{@api_version}>"

    # Identity of the token itself. Cached: the CLI asks for it when building
    # error messages, which can happen more than once per run.
    def me
      @lock.synchronize { @me ||= fetch_me }
    end

    # Human name of the connection or person this token authenticates as, for
    # error messages that have to tell someone what to share a page with.
    def connection_name
      me["name"] || "your integration"
    end

    # What kind of credential this is: :person for a personal access token,
    # :bot_user for a connection a user owns, or :bot_workspace for an internal
    # connection owned by the workspace. Only the last cannot act as anyone.
    def credential_kind
      case me["type"]
      when "person" then :person
      when "bot"
        me.dig("bot", "owner", "type") == "user" ? :bot_user : :bot_workspace
      end
    end

    private

    def fetch_me
      get("/v1/users/me").tap do |found|
        @log&.note("authenticated as #{found['name'].inspect} in #{found.dig('bot', 'workspace_name').inspect}")
      end
    end

    def multipart(boundary, path, content_type)
      # Force binary: joining image bytes with UTF-8 strings raises otherwise.
      [
        "--#{boundary}\r\n",
        %(Content-Disposition: form-data; name="file"; filename="#{File.basename(path)}"\r\n),
        "Content-Type: #{content_type}\r\n\r\n",
        File.binread(path),
        "\r\n--#{boundary}--\r\n"
      ].map { |part| part.dup.force_encoding(Encoding::BINARY) }.join
    end

    def authorized(req)
      req["Authorization"] = "Bearer #{@token}"
      req["Notion-Version"] = @api_version
      req["User-Agent"] = USER_AGENT
      req
    end

    def build(klass, path, body, query)
      uri = URI.join(API_ORIGIN, path)
      uri.query = URI.encode_www_form(query.compact) if query && !query.empty?

      req = authorized(klass.new(uri))
      req["Accept"] = "application/json"
      if body
        req["Content-Type"] = "application/json"
        req.body = JSON.generate(body)
      end
      req
    end

    def request(klass, path, body: nil, query: nil, attempt: 1)
      req = build(klass, path, body, query)
      started = monotonic
      response = http.request(req)
      status = response.code.to_i
      trace(req, response, monotonic - started)

      if RETRYABLE_STATUSES.include?(status) && attempt < MAX_ATTEMPTS
        delay = retry_delay(response, attempt)
        @log&.retrying(status, delay, attempt, MAX_ATTEMPTS)
        @sleeper.call(delay)
        return request(klass, path, body: body, query: query, attempt: attempt + 1)
      end

      parsed = parse(response)
      return parsed if status.between?(200, 299)

      error_class = status == 429 ? RateLimited : ApiError
      raise error_class.new(status: status, body: parsed)
    end

    def trace(req, response, seconds, sent: req.body)
      return unless @log

      @log.request(req.method, req.uri, response.code, seconds)
      @log.body(">", sent)
      @log.body("<", response.body)
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # Notion sends Retry-After on 429. Everything else gets exponential backoff.
    def retry_delay(response, attempt)
      after = response["Retry-After"].to_f
      return after if after.positive?

      2**(attempt - 1)
    end

    def parse(response)
      body = response.body.to_s
      return {} if body.empty?

      JSON.parse(body)
    rescue JSON::ParserError
      { "code" => "invalid_response", "message" => body[0, 200] }
    end

    # One connection per thread, kept open for the run: a publish makes a
    # dozen calls.
    def http
      @lock.synchronize { @connections[Thread.current] ||= connect }
    end

    def connect
      uri = URI(API_ORIGIN)
      connection = Net::HTTP.new(uri.host, uri.port)
      connection.use_ssl = true
      connection.open_timeout = 10
      connection.read_timeout = 60
      connection.start
      connection
    end
  end
end
