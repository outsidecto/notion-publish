# frozen_string_literal: true

require "optparse"

require_relative "client"
require_relative "commands"
require_relative "errors"
require_relative "log"
require_relative "page_map"
require_relative "version"

module NotionPublish
  # The notion-publish command line: parses options, dispatches to a command,
  # and turns failures into messages and exit codes.
  class CLI
    OK = 0
    FAILURE = 1
    USAGE = 2
    # Stopped and needs a decision, so a dry run in CI can gate a merge on
    # "this would need a human" without that reading as a crash.
    BLOCKED = 3
    # The shell convention for a process stopped by SIGINT.
    INTERRUPTED = 130

    SUBCOMMANDS = %w[adopt properties relink republish status].freeze

    # Everything a command needs from the invocation. The client is built on
    # first use, so a usage error never demands a token.
    class Context
      attr_reader :options, :stdout, :stderr, :stdin

      def initialize(options:, stdout:, stderr:, stdin:, client: nil)
        @options = options
        @stdout = stdout
        @stderr = stderr
        @stdin = stdin
        @client = client
      end

      # Under -v, say up front which connection and workspace the token
      # belongs to. That is the first question when a page cannot be found and
      # more than one token is in use.
      def client
        @client ||= Client.new(token: options[:token], log: log).tap { |c| c.me if options[:verbose] }
      end

      def log
        Log.new(stderr, options[:verbose]) if options[:verbose]
      end
    end

    def self.run(argv, stdout: $stdout, stderr: $stderr, stdin: $stdin)
      new(stdout: stdout, stderr: stderr, stdin: stdin).run(argv)
    end

    def initialize(stdout: $stdout, stderr: $stderr, stdin: $stdin, client: nil)
      @options = {}
      @context = Context.new(options: @options, stdout: stdout, stderr: stderr, stdin: stdin, client: client)
    end

    def run(argv)
      argv = Array(argv).dup
      subcommand = SUBCOMMANDS.include?(argv.first) ? argv.shift : nil
      args = parser.parse(argv)

      return print_help if @options[:help]
      return print_version if @options[:version]
      return Commands::Whoami.new(@context).call if @options[:whoami]

      dispatch(subcommand, args)
    rescue OptionParser::ParseError => e
      usage(e.message)
    rescue ApiError => e
      # ApiError is an Error, so it has to be rescued first.
      stderr.puts api_failure(e)
      FAILURE
    rescue Error => e
      stderr.puts e.message
      FAILURE
    rescue Interrupt
      stderr.puts "Interrupted."
      INTERRUPTED
    end

    private

    def stdout = @context.stdout
    def stderr = @context.stderr

    def dispatch(subcommand, args)
      case subcommand
      when "properties" then Commands::Properties.new(@context).call
      when "status" then Commands::Status.new(@context).call(args.first || Dir.pwd)
      when "relink" then Commands::Relink.new(@context).call(args.first || Dir.pwd)
      when "republish" then Commands::Republish.new(@context).call(args.first || Dir.pwd)
      when "adopt"
        return usage("Give one Markdown file to adopt.") unless args.length == 1

        Commands::Adopt.new(@context).call(args.first)
      else publish(args)
      end
    end

    def publish(files)
      case files.length
      when 1 then Commands::Publish.new(@context).call(files.first)
      when 0 then usage("No Markdown file given.")
      else usage("Give one Markdown file at a time (got #{files.length}).")
      end
    end

    def print_help
      stdout.puts parser.help
      OK
    end

    def print_version
      stdout.puts "notion-publish #{VERSION}"
      OK
    end

    def usage(message)
      stderr.puts message
      stderr.puts
      stderr.puts parser.help
      USAGE
    end

    def api_failure(error)
      return error.message unless error.restricted?

      <<~MSG.strip
        #{@context.client.connection_name.inspect} is not allowed to do that (#{error.code}).

        Check the connection's capabilities in the Notion developer portal.
        Publishing needs "Insert content".
      MSG
    end

    # One line per option is easier to scan than any attempt to shorten it.
    # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength, Metrics/BlockLength
    def parser
      @parser ||= OptionParser.new do |o|
        o.banner = <<~BANNER.strip
          Usage: notion-publish FILE [options]
                 notion-publish republish [DIR]        update every page notion-pages.yml tracks
                 notion-publish properties [options]   show the destination's schema
                 notion-publish relink [DIR]           fix links to documents published later
                 notion-publish adopt FILE [options]   record a page this file already corresponds to
                 notion-publish status [DIR]           what would happen if you published everything
        BANNER
        o.separator ""
        o.separator "Destination (first one given wins):"
        o.on("-p", "--parent ID_OR_URL_OR_NAME", "Where to publish: an ID, a Notion URL, or a database name") do |v|
          @options[:parent] = v
        end
        o.on("-d", "--database NAME", "Force name lookup (for a database named like an ID)") do |v|
          @options[:database] = v
        end
        o.separator ""
        o.separator "Options:"
        o.on("-P", "--property NAME=VALUE", "Set a property; repeat for multi-valued ones") do |v|
          (@options[:properties] ||= []) << v
        end
        o.on("--properties-json JSON", "Set properties from a JSON object") { |v| @options[:properties_json] = v }
        o.on("--no-upload", "Do not upload local images (they will not render)") { @options[:upload] = false }
        o.on("--icon ICON", "Page icon: an emoji, an image URL, or a path to an image") { |v| @options[:icon] = v }
        o.on("--cover COVER", "Page cover: an image URL or a path to an image") { |v| @options[:cover] = v }
        o.on("--keep-h1", "Keep the leading H1 in the body as well as the title") { @options[:keep_h1] = true }
        o.on("--link", "Record this page so it can be updated and linked to") { @options[:link] = true }
        o.on("--no-link", "Do not record or update; always create a new page") { @options[:link] = false }
        o.on("--pages-file PATH", "Identity map to use (default: #{PageMap::FILENAME} at the repo root)") do |v|
          @options[:pages_file] = v
        end
        o.on("--local", "status: do not check Notion, use the recorded hashes only") { @options[:local] = true }
        o.on("--untracked", "status: list files that were never published") { @options[:untracked] = true }
        o.on("--page URL_OR_ID", "adopt: the page this file already corresponds to") { |v| @options[:page] = v }
        o.on("-y", "--yes", "adopt: accept a title match without confirming") { @options[:yes] = true }
        o.on("--force-properties", "Reapply properties even if nothing else changed") do
          @options[:force_properties] = true
        end
        o.on("-f", "--force", "Publish even if the Notion page changed since it was published") do
          @options[:force] = true
        end
        o.on("-t", "--title TITLE", "Page title (default: front matter, first heading, or filename)") do |v|
          @options[:title] = v
        end
        o.on("-n", "--dry-run", "Resolve and validate, write nothing") { @options[:dry_run] = true }
        o.on("--json", "Emit one JSON object per document on stdout") { @options[:json] = true }
        o.on("--token TOKEN", "API token (default: $#{Client::TOKEN_ENV_VARS.join(', $')})") do |v|
          @options[:token] = v
        end
        o.on("--whoami", "Show what the token authenticates as") { @options[:whoami] = true }
        o.on("-q", "--quiet", "Only report files where something happened") { @options[:quiet] = true }
        o.on("--no-progress", "Do not show a progress line in a terminal") { @options[:no_progress] = true }
        o.on("-v", "--verbose", "Log each API request to stderr; -vv adds shortened bodies") do
          @options[:verbose] = (@options[:verbose] || 0) + 1
        end
        o.on("--version", "Show version") { @options[:version] = true }
        o.on("-h", "--help", "Show this message") { @options[:help] = true }
      end
    end
  end
end
