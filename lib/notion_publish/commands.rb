# frozen_string_literal: true

require_relative "commands/command"
require_relative "commands/adopt"
require_relative "commands/properties"
require_relative "commands/publish"
require_relative "commands/relink"
require_relative "commands/republish"
require_relative "commands/status"
require_relative "commands/whoami"

module NotionPublish
  # One class per subcommand. Each takes a CLI::Context and returns an exit
  # code from #call.
  module Commands
  end
end
