# frozen_string_literal: true

require "yaml"

require_relative "errors"

module NotionPublish
  # Hand-written configuration. The tool reads it and never writes it, so
  # comments and formatting survive -- Ruby's YAML discards comments on read and
  # cannot put them back, which is why anything the tool rewrites lives in
  # PageMap instead.
  #
  # Every .notion-publish.yml from the repository root down to the document's
  # own directory is merged, closest winning, the way .rubocop.yml and
  # .editorconfig behave.
  class Settings
    FILENAME = ".notion-publish.yml"
    KEYS = %w[parent database icon cover].freeze

    attr_reader :data, :files

    def self.for(dir)
      dirs = ancestors(File.expand_path(dir))
      files = dirs.map { |d| File.join(d, FILENAME) }.select { |f| File.file?(f) }
      new(files)
    end

    # Outermost first, so nearer files overwrite farther ones on merge. Stops at
    # a git repository root when there is one.
    def self.ancestors(dir)
      chain = []
      loop do
        chain << dir
        break if File.directory?(File.join(dir, ".git"))

        parent = File.dirname(dir)
        break if parent == dir

        dir = parent
      end
      chain.reverse
    end

    def initialize(files)
      @files = files
      @data = files.reduce({}) { |merged, file| merged.merge(load_file(file)) }
    end

    KEYS.each { |key| define_method(key) { data[key] } }

    def empty? = data.empty?

    private

    def load_file(path)
      loaded = YAML.safe_load_file(path, permitted_classes: [], aliases: false) || {}
      raise ConfigError, "#{path} must contain a YAML mapping" unless loaded.is_a?(Hash)

      check_keys!(path, loaded.keys)
      loaded.slice(*KEYS)
    rescue Psych::Exception => e
      raise ConfigError, "Could not parse #{path}: #{e.message}"
    end

    # pages and databases are state from before it moved to PageMap. They are
    # tolerated so an old file still loads; PageMap migrates them.
    def check_keys!(path, keys)
      unknown = keys - KEYS - %w[pages databases]
      return if unknown.empty?

      raise ConfigError, "#{path}: unknown setting#{'s' if unknown.length > 1} " \
                         "#{unknown.map(&:inspect).join(', ')}. Known settings: #{KEYS.join(', ')}."
    end
  end
end
