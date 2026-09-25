# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-09-24

First public release.

### Added

- Publish a Markdown file to a Notion page, database, or data source, named by ID, URL, or exact
  database name.
- Update the same page in place on later runs, using a committed identity map
  (`notion-pages.yml`).
- Set database properties from front matter, `--properties-json`, or `--property`, validated
  against the live schema before anything is written.
- Upload local images and place them as image blocks.
- Page icon and cover from an emoji, URL, or local file.
- Detect edits made in Notion since the last publish and stop (exit 3) unless `--force` is given.
- `status`, `relink`, `adopt`, and `properties` subcommands.
- `--dry-run` and `--json` output for CI.

[Unreleased]: https://github.com/outsidecto/notion-publish/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/outsidecto/notion-publish/releases/tag/v0.1.0
