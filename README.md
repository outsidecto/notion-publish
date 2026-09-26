# notion-publish

[![CI](https://github.com/outsidecto/notion-publish/actions/workflows/ci.yml/badge.svg)](https://github.com/outsidecto/notion-publish/actions/workflows/ci.yml)
[![Gem Version](https://badge.fury.io/rb/notion_publish.svg)](https://rubygems.org/gems/notion_publish)

Keep Notion pages in step with Markdown files in a Git repository.

Many teams write their documents in Git, where changes are reviewed and every version is kept. The
people who read those documents often work in Notion. `notion-publish` publishes each Markdown file
as a Notion page, and later runs update the same page in place. Git stays the source of truth, and
Notion shows a current copy.

```console
$ notion-publish policies/access-control.md --parent Policies --link
Published policies/access-control.md to database "Policies" (2efab123-...)
  https://app.notion.com/p/Access-Control-Policy-3cfab123cd45818b9a72c2bd16e85a62

$ notion-publish policies/access-control.md
Unchanged policies/access-control.md
```

## What it does

- **Updates pages in place.** A committed file, `notion-publish-manifest.yml`, records which page
  each file became. Republishing replaces the page body and keeps its URL, so links to it keep
  working.
- **Republishes everything it tracks** with one command, `notion-publish republish`, using what it
  recorded about each file.
- **Protects edits made in Notion.** If someone edited the page in Notion since the last publish,
  the tool stops and exits with code 3 rather than overwriting their work.
- **Sets database properties** from front matter or flags. Values are checked against the database
  schema before anything is written, so a typo in a select option fails instead of creating a new
  option.
- **Rewrites links between documents** to their Notion URLs.
- **Uploads local images** and places them in the page.
- **Fixes wrapped text.** Notion treats each line of a hard-wrapped paragraph as its own block. The
  tool joins the lines first.
- **Reports drift.** `notion-publish status` lists files changed locally, pages changed in Notion
  or moved to Notion's trash, and files that were never published.

Notion does the Markdown conversion itself, through its
[Markdown API](https://developers.notion.com/). The gem has no runtime dependencies beyond the Ruby
standard library.

## Install

Requires Ruby 3.2 or later.

    gem install notion_publish

Or add it to a Gemfile:

```ruby
gem "notion_publish", require: false
```

## Quick start

1. **Create a connection.** Go to
   [notion.so/profile/integrations](https://www.notion.so/profile/integrations), create an internal
   connection, and give it the Read, Update, and Insert content capabilities. Copy the token.

2. **Share a destination with it.** In Notion, open the page or database you will publish into,
   choose **••• → Connections**, and add your connection.

3. **Set the token.**

       export NOTION_API_TOKEN=ntn_...
       notion-publish --whoami

4. **Publish.** `--parent` takes a page or database ID, a Notion URL, or the exact name of a
   database.

       notion-publish docs/onboarding.md --link \
         --parent 'https://app.notion.com/p/Team-Docs-2efab123...'

   `--link` creates `notion-publish-manifest.yml` at the repository root. Commit it. Without it,
   the next run cannot find the page and will create a second copy.

5. **Edit the file and publish again.** The page is updated in place.

## Keeping a repository in sync

Put the destination in a settings file, so it does not have to be typed each time. Settings apply
to the directory they are in and everything below it.

```yaml
# policies/.notion-publish.yml
database: Policies
icon: 📘
```

Set database properties in each file's front matter:

```markdown
---
properties:
  Owner: Jane Doe
  Status: Approved
  Review Date: 2027-01-15
---
# Access Control Policy
...
```

The first time, publish the directory with a loop. Then run `relink` to fix links to documents
that were published later in the loop:

```sh
for f in policies/*.md; do
  notion-publish "$f" --link
done
notion-publish relink
```

After that, one command updates every page the manifest tracks:

```console
$ notion-publish republish
Updated policies/incident-response.md to database "Policies" (2efab123-...)
  https://app.notion.com/p/Incident-Response-Policy-...
12 documents: 11 unchanged, 1 updated
```

Only files where something happened are listed. `-v` lists every file. In a terminal, a progress
line shows which file is being checked while it runs.

`republish` needs no file names and no destination. Each page is updated where it already is, from
the file's current front matter plus any `--title` or `--keep-h1` it was last published with.
Properties that were set with `--property` are left as they are. A new file is not picked up until
you publish it once by name.

Check where things stand at any time:

```console
$ notion-publish status
/repo/notion-publish-manifest.yml -- 12 tracked

Changed locally (1)
  policies/access-control.md

Changed in Notion (1)
  policies/incident-response.md
    https://app.notion.com/p/...

10 in sync, 1 changed locally, 1 changed in Notion
```

`status -v` also lists the documents that are in sync.

### Publishing from GitHub Actions

This workflow republishes on every push to `main` and commits the updated manifest back.
Store the token as a repository secret named `NOTION_API_TOKEN`.

```yaml
name: Publish to Notion

on:
  push:
    branches: [main]
    paths: ["policies/**.md"]

permissions:
  contents: write

jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: "3.4"
      - run: gem install notion_publish
      - name: Republish
        env:
          NOTION_API_TOKEN: ${{ secrets.NOTION_API_TOKEN }}
        run: notion-publish republish
      - name: Commit notion-publish-manifest.yml
        if: success() || failure()
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git add notion-publish-manifest.yml
          if ! git diff --cached --quiet; then
            git commit -m "Record published Notion pages"
            git push
          fi
```

If a page was edited in Notion, `republish` leaves it alone and exits with code 3, which fails the
job. The other files still publish. Look at the page, move the change into the Markdown, and publish
that file with `--force`.

## Documentation

[docs/usage.md](docs/usage.md) is the full reference. It covers destinations, settings, every
property type, the manifest, adopting pages that already exist, images, exit codes, and JSON
output.

## What to put in your own README

Somebody who joins the repository you publish from will find `notion-publish-manifest.yml` in the
root and have no idea what it is or what they are allowed to change. A pointer to this page does not
help them much. Here is a section to copy into that repository's README instead, with the
destination and the token filled in:

```markdown
## Publishing to Notion

These documents are mirrored into Notion. Git is the authoritative copy. Edit the Markdown here and
never the Notion page: publishing replaces the page body, so an edit made in Notion gets discarded.

`notion-publish-manifest.yml` records which Notion page each file became. The tool writes it and we
commit it. Do not edit it by hand.

Once, to set up:

    gem install notion_publish
    export NOTION_API_TOKEN=...      # ask <who has it> for the token

| What you want to do              | Command                                          |
|----------------------------------|--------------------------------------------------|
| See what is out of step          | `notion-publish status`                          |
| Update Notion after editing      | `notion-publish republish`                       |
| Add a document Notion lacks      | `notion-publish <file> --parent '<dest>' --link` |
| Point a file at an existing page | `notion-publish adopt <file> --page <url>`       |
| Replace a page edited in Notion  | `notion-publish <file> --force`                  |

`status` only reads, so it is always safe to run first.

If a run reports that a page changed in Notion, somebody edited the mirror. Open the page, move
anything worth keeping into the Markdown here, then publish that one file with `--force`.

Commit the manifest along with your change, so the next person's run knows what happened.
```

Two things are worth keeping when you adapt it. Name someone who can hand over the token, because
that is where a new person gets stuck first. And keep the line about not editing pages in Notion:
the tool will refuse to overwrite such an edit, but only after somebody has already spent time
making it.

## Known limits

- A new file must be published once by name before `republish` includes it.
- Images inside a paragraph cannot be placed, since Notion has no inline images.
- Files over 20 MB are not uploaded, because Notion's multi-part upload is not implemented.
- H5 and H6 become heading 4 in Notion.

## Development

    bundle install
    bundle exec rake     # tests and RuboCop

Tests use Minitest and WebMock and make no network calls. Bug reports and pull requests are welcome
at [github.com/outsidecto/notion-publish](https://github.com/outsidecto/notion-publish). To report a
security problem, see [SECURITY.md](SECURITY.md).

## License

MIT. See [LICENSE](LICENSE).

This project is not affiliated with or endorsed by Notion Labs, Inc.
