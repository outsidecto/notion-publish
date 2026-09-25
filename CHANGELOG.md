# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `-v` logs each API request to stderr, with status, timing, and retries, and names the workspace
  the token belongs to, even for commands that would not otherwise ask. `-vv` adds shortened request and response bodies. The token is never
  logged.
- `notion-publish republish [DIR]` updates every page the identity map tracks, without naming
  files. Each page is updated where it already is. Options that name a destination or describe a
  single document are ignored with a warning.
- Entries in `notion-pages.yml` record `flag_properties` (properties set with `--property` or
  `--properties-json`), `title_override` (`--title`), and `keep_h1` (`--keep-h1`), so `republish`
  can repeat what the last publish of each file did.

### Fixed

- `relink` now records each fixed page's new Notion hash when the page was in sync beforehand.
  Before, every relinked page then read as "changed in Notion" and blocked the next publish.
- A page deleted in Notion sits in the trash, where the API still returns it. `status` reported
  such a page as in sync or changed in Notion, and publishing tried to update it. `status` now
  reports "page is in Notion's trash", and publishing forgets the entry and creates a new page.

### Changed

- `status` groups documents by state, lists the ones in sync, and counts files that were never
  published instead of listing them. `--untracked` lists them.
- `properties_sha256` now covers only the property values that came from the document. Flag-set
  values have their own hash, `flag_properties_sha256`. Entries published without flags keep the
  same hash, so they still report `Unchanged`.
- `republish` leaves flag-set properties alone. It updates an entry written before
  `flag_properties` existed only when front matter reproduces its recorded properties, and
  otherwise skips it with an explanation.

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
