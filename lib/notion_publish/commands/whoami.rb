# frozen_string_literal: true

require_relative "command"

module NotionPublish
  module Commands
    # Says what the token authenticates as, which is the first thing to check
    # when a page cannot be reached.
    class Whoami < Command
      KINDS = {
        person: "personal access token (acts as a person)",
        bot_user: "connection owned by a user",
        bot_workspace: "internal connection owned by the workspace"
      }.freeze

      def call
        stdout.puts "#{client.connection_name} -- #{KINDS.fetch(client.credential_kind, 'unknown credential')}"
        stdout.puts "  id:            #{client.me['id']}"
        if (workspace = client.me.dig("bot", "workspace_name"))
          stdout.puts "  workspace:     #{workspace}"
        end
        stdout.puts "  API version:   #{client.api_version}"
        CLI::OK
      end
    end
  end
end
