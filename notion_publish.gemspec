# frozen_string_literal: true

require_relative "lib/notion_publish/version"

Gem::Specification.new do |spec|
  spec.name = "notion_publish"
  spec.version = NotionPublish::VERSION
  spec.authors = ["John Norman"]
  spec.email = ["john@outsidecto.com"]

  spec.summary = "Publish Markdown files from a Git repository into Notion, and keep them in sync"
  spec.description = <<~TEXT
    A command-line tool that publishes Markdown files as Notion pages and
    updates them in place on later runs. It uses Notion's Markdown endpoints,
    so Notion does the conversion to blocks. It records which page each file
    became, sets database properties from front matter, uploads local images,
    and refuses to overwrite a page someone has edited in Notion. Not
    affiliated with or endorsed by Notion Labs, Inc.
  TEXT
  spec.homepage = "https://outsidecto.com/notion-publish/"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  # rubygems.org shows homepage and source code as separate links, so the
  # project page and the repository do not have to be the same URL.
  repository = "https://github.com/outsidecto/notion-publish"
  spec.metadata["source_code_uri"] = repository
  spec.metadata["changelog_uri"] = "#{repository}/blob/main/CHANGELOG.md"
  spec.metadata["documentation_uri"] = "#{repository}/blob/main/docs/usage.md"
  spec.metadata["bug_tracker_uri"] = "#{repository}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.rb", "exe/*", "docs/**/*.md", "README.md", "CHANGELOG.md", "LICENSE"]
  spec.bindir = "exe"
  spec.executables = ["notion-publish"]
  spec.require_paths = ["lib"]
end
