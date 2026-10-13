# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- GitHub alerts (`> [!NOTE]`, `[!TIP]`, `[!IMPORTANT]`, `[!WARNING]`, `[!CAUTION]`) are published
  as Notion callouts with an icon and colour for each type. Notion showed them as quotes containing
  the marker.
- A code block that shows a fence, such as a ```` ``` ```` example inside a ````` ```` ````` fence,
  is inserted through the block API. Notion's Markdown cannot hold it.

### Fixed

- A code fence now ends only where CommonMark ends it: a run of the same character, at least as
  long as the opening one. A ```` ``` ```` line inside a ````` ```` ````` or `~~~` fence used to
  end it, so the code after it was joined into paragraphs, and links and images in it were
  rewritten.
- Fences are sent in the one form Notion's parser reads: three backticks and Notion's name for the
  language. Tilde fences and longer backtick fences used to arrive as text, and a label with more
  than one word was ignored.
- A fence with no label, or one Notion does not know such as `console`, is labelled `plain text`
  or mapped to Notion's name. Notion used to highlight it as JavaScript.

## [0.1.0] - 2026-09-26

First public release.

### Added

- Publish a Markdown file to a Notion page, database, or data source, named by ID, URL, or exact
  database name. Notion does the Markdown conversion.
- Update the same page in place on later runs. `notion-publish-manifest.yml`, which you commit,
  records which page each file became, so a tracked file needs no destination.
- `republish [DIR]` updates every page the manifest tracks, from each file's front matter plus the
  `--title` and `--keep-h1` it was last published with. Properties set with flags are left alone.
- Set database properties from front matter, `--properties-json`, or `--property`, validated
  against the live schema before anything is written. Properties the tool set before and no longer
  sets are cleared; properties it never set are left alone.
- Detect edits made in Notion since the last publish, and pages moved to Notion's trash. An edited
  page stops the publish with exit code 3 unless `--force` is given; a trashed page is published
  afresh.
- Upload local images, including images under list items, and place them as image blocks.
- Join hard-wrapped lines before sending, since Notion makes a block of each line.
- Rewrite links between published documents to their Notion URLs, with `relink` for a second pass.
- Page icon and cover from an emoji, URL, or local file.
- `status`, `relink`, `adopt`, and `properties` subcommands.
- Check three pages at a time in `republish`, `status`, and `relink`; `-j`/`--jobs` changes the
  number. A progress line appears when stderr is a terminal.
- Output lists only files where something happened. `-v` lists every file, `-vv` logs each API
  request, and `-vvv` adds shortened bodies. The token is never logged.
- `--dry-run` and `--json` output for scripts and CI.

[Unreleased]: https://github.com/outsidecto/notion-publish/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/outsidecto/notion-publish/releases/tag/v0.1.0
