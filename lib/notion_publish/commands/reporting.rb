# frozen_string_literal: true

require "json"

module NotionPublish
  module Commands
    # How a publish outcome is shown, shared by publish and republish so a
    # script sees the same lines and the same JSON from either.
    module Reporting
      private

      # Prints the outcome and returns the exit code it deserves on its own.
      def report(path, outcome, target, warnings)
        warnings.each { |w| stderr.puts w }
        report_json(path, outcome, target) if options[:json]

        case outcome.action
        when :blocked
          stderr.puts outcome.detail
          CLI::BLOCKED
        when :skipped
          stderr.puts "Skipped #{path}"
          stderr.puts outcome.detail
          CLI::BLOCKED
        else
          report_text(path, outcome, target) unless options[:json]
          CLI::OK
        end
      end

      def report_json(path, outcome, target)
        stdout.puts JSON.generate(
          "source" => path, "action" => outcome.action.to_s,
          "id" => outcome.id, "url" => outcome.url,
          "parent" => target.id, "parent_name" => target.title
        )
      end

      def report_text(path, outcome, target)
        case outcome.action
        when :unchanged
          stdout.puts "Unchanged #{path}"
          return
        when :properties then stdout.puts "Updated properties on #{path}"
        when :created then stdout.puts "Published #{path} to #{target.describe}"
        else stdout.puts "Updated #{path} to #{target.describe}"
        end
        stdout.puts "  #{outcome.url}"
      end
    end
  end
end
