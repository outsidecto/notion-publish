# frozen_string_literal: true

require_relative "notion_publish/version"
require_relative "notion_publish/errors"
require_relative "notion_publish/notion_digest"
require_relative "notion_publish/reference"
require_relative "notion_publish/target"
require_relative "notion_publish/sharing"
require_relative "notion_publish/client"
require_relative "notion_publish/resolver"
require_relative "notion_publish/adopter"
require_relative "notion_publish/settings"
require_relative "notion_publish/document"
require_relative "notion_publish/property_set"
require_relative "notion_publish/schema"
require_relative "notion_publish/users"
require_relative "notion_publish/decoration"
require_relative "notion_publish/fixups"
require_relative "notion_publish/links"
require_relative "notion_publish/page_map"
require_relative "notion_publish/status"
require_relative "notion_publish/media"
require_relative "notion_publish/uploader"
require_relative "notion_publish/publisher"
require_relative "notion_publish/cli"

# Publishes Markdown files into Notion as pages, and keeps them updated in
# place. See NotionPublish::CLI for the command line and
# NotionPublish::Publisher for the library entry point.
module NotionPublish
end
