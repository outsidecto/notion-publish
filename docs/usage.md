# Usage reference

This is the full reference for `notion-publish`. For an overview and a quick start, see the
[README](../README.md).

- [Command summary](#command-summary)
- [Authentication](#authentication)
- [Choosing a destination](#choosing-a-destination)
- [Settings file](#settings-file)
- [Properties](#properties)
- [Title, icon, and cover](#title-icon-and-cover)
- [Republishing and the identity map](#republishing-and-the-identity-map)
- [Publishing a set of files](#publishing-a-set-of-files)
- [Republishing everything](#republishing-everything)
- [Links between documents](#links-between-documents)
- [Adopting pages that already exist](#adopting-pages-that-already-exist)
- [Checking status](#checking-status)
- [Local images](#local-images)
- [What is changed before publishing](#what-is-changed-before-publishing)
- [Scripting and exit codes](#scripting-and-exit-codes)
- [How Notion treats Markdown](#how-notion-treats-markdown)
- [Known limits](#known-limits)

## Command summary

    notion-publish FILE [options]             publish one Markdown file
    notion-publish status [DIR]               what would happen if you published everything
    notion-publish republish [DIR]            update every page notion-pages.yml tracks
    notion-publish relink [DIR]               fix links to documents published later
    notion-publish adopt FILE [options]       record a page this file already corresponds to
    notion-publish properties [options]       show the destination's schema
    notion-publish --whoami                   show what the token authenticates as

Options:

| Option                        | Meaning                                                         |
|-------------------------------|-----------------------------------------------------------------|
| `-p`, `--parent VALUE`        | Destination: an ID, a Notion URL, or an exact database name     |
| `-d`, `--database NAME`       | Destination by name, for a database whose name looks like an ID |
| `-P`, `--property NAME=VALUE` | Set a property; repeat for multi-valued properties              |
| `--properties-json JSON`      | Set properties from a JSON object                               |
| `-t`, `--title TITLE`         | Page title                                                      |
| `--icon ICON`                 | Emoji, image URL, or path to a local image                      |
| `--cover COVER`               | Image URL or path to a local image                              |
| `--keep-h1`                   | Keep the leading H1 in the body as well as using it as title    |
| `--no-upload`                 | Do not upload local images                                      |
| `--link`                      | Record the page in `notion-pages.yml`                           |
| `--no-link`                   | Do not read or write `notion-pages.yml`; always create a page   |
| `--pages-file PATH`           | Use this identity map instead of looking for one                |
| `-f`, `--force`               | Overwrite a page that was edited in Notion                      |
| `--force-properties`          | Reapply properties even when nothing changed                    |
| `-n`, `--dry-run`             | Resolve and validate; write nothing                             |
| `--json`                      | One JSON object per document on stdout                          |
| `--local`                     | `status` only: do not ask Notion, compare local hashes only     |
| `--page URL_OR_ID`            | `adopt` only: the page this file corresponds to                 |
| `-y`, `--yes`                 | `adopt` only: accept a title match without asking               |
| `--token TOKEN`               | API token, instead of the environment                           |
| `--version`, `-h`, `--help`   |                                                                 |

## Authentication

Create an internal connection (integration) at
[notion.so/profile/integrations](https://www.notion.so/profile/integrations) and give it the
**Read content**, **Update content**, and **Insert content** capabilities. Copy its token.

Set the token in the environment:

    export NOTION_API_TOKEN=ntn_...

`NOTION_API_TOKEN` is checked first because Notion's own `ntn` CLI reads it. `NOTION_API_KEY` is
accepted as a fallback because Notion's quickstart tells people to set that one. `--token` also
works, but command-line arguments are visible to other users through the process list.

A connection can only see pages that are shared with it. In Notion, open the page or database you
will publish into, choose **••• → Connections**, and add the connection. Pages nested below it are
shared automatically. An inline database has no connection menu of its own, so share the page it
sits on.

Check what the token authenticates as:

    $ notion-publish --whoami
    Docs Publisher -- internal connection owned by the workspace
      id:            1a2b3c4d-...
      workspace:     Acme
      API version:   2026-03-11

When something cannot be found, Notion returns the same error whether it does not exist or is not
shared with the connection. `notion-publish` says so rather than guessing which one it is.

## Choosing a destination

Every Notion page needs a parent. An internal connection cannot create pages at the top level of a
workspace, so there is no default. The destination comes from the first of these that is set:

1. `--parent` or `--database` on the command line
2. `notion_parent:` or `notion_database:` in the file's front matter
3. `parent:` or `database:` in `.notion-publish.yml`

`--parent` accepts three forms and works out which one it was given:

    --parent 2efab123cd458061b273eac31bb95510
    --parent 'https://app.notion.com/p/Some-Page-2efab123cd458061b273eac31bb95510?v=...'
    --parent 'Policies'

A value that is only a 32-character ID or a dashed UUID is an ID. Anything that looks like a URL is
a URL. Anything else is a database name. The ID check is anchored, so `'Q3 Report 2efab123...'` is
treated as a name. A `?v=` view ID in a URL is ignored.

An ID or URL may name a page, a database, or a data source, and you do not have to say which. Page
IDs and database IDs look the same in a URL, so the tool asks Notion what the ID is.

Database names must match exactly, ignoring case. Notion's search is fuzzy and ranked by relevance,
so the tool never publishes into a near match. If there is no exact match, it lists the close ones
with their IDs. `--database` forces name lookup, for a database whose name happens to look like an
ID.

Since API version 2025-09-03, a Notion database is a container for one or more data sources, and the
schema and rows belong to the data source. A database with one data source resolves to it. A
database with two or more is reported as ambiguous, with the ID of each, so you can pick one.

## Settings file

`.notion-publish.yml` holds settings that you write by hand. The tool reads it and never rewrites
it, so your comments survive.

```yaml
# Everything under this directory goes to the Policies database.
database: Policies
icon: 🔒
```

The keys are `parent`, `database`, `icon`, and `cover`. An unknown key is an error, so a typo does
not get ignored.

Every `.notion-publish.yml` from the repository root down to the document's own directory is read,
and the nearest one wins for each key. That works the same way as `.editorconfig`. The search stops
at the directory that contains `.git`.

## Properties

When the destination is a database, the page's properties come from three layers. A later layer
replaces an earlier one for the same property name.

1. Front matter, under a `properties:` key:

   ```yaml
   ---
   properties:
     Function: [Operations, Security and Compliance]
     Status: Draft
     Due Date: 2026-09-15
   ---
   ```

2. `--properties-json '{"Function": ["Legal"], "Due Date": "2026-09-15"}'`

3. `--property`, repeated for multi-valued properties:

       --property 'Function=Operations' --property 'Function=Security and Compliance'

`--property` splits on the first `=`, so names may contain spaces and values may contain anything.
An empty value clears a property: `--property 'Owner='`.

To see what a destination accepts:

    $ notion-publish properties --parent Policies
    database "Policies" (2efab123-...)
      Name                     title
      Function                 multi_select
        Operations | Security and Compliance | Legal
      Owner                    people
      Due Date                 date
      Last edited by           last_edited_by (read-only)

### Validation

The schema is fetched before anything is written, so the syntax needs no type information and many
mistakes are caught early:

- An unknown `select`, `multi_select`, or `status` option is refused. Notion would create the option
  rather than reject it, so a typo would quietly add to the schema.
- Giving two values to a single-valued property is an error, not "last one wins".
- A misspelled property name gets "did you mean" suggestions.
- Computed properties (`formula`, `rollup`, `last_edited_by`, and so on) are reported as owned by
  Notion.
- `people` accepts a user ID or a person's exact name.
- `date` accepts `2026-09-15` or a range, `2026-09-15..2026-09-20`.
- `checkbox` accepts `true`/`false`, `yes`/`no`, or `1`/`0`.
- `relation` accepts page IDs or Notion URLs.
- `files` properties cannot be set.

### Which properties the tool owns

Publishing is declarative over the properties the tool has set before. Each entry in
`notion-pages.yml` records the names of the properties it set. On the next publish:

| Property | Set in this run | Set by the tool before | Result     |
|----------|-----------------|------------------------|------------|
| Function | yes             | yes                    | updated    |
| Owner    | no              | yes                    | cleared    |
| Status   | no              | no                     | left alone |

A property the tool never set belongs to someone else. For example, a reviewer may change `Status`
in Notion, and publishing will not touch it.

### Page parents

A page under another page has no properties, only a title. Front matter properties written for a
database are skipped with a warning, so the document still publishes. A `--property` flag given
explicitly is an error.

## Title, icon, and cover

The title comes from `--title`, then `title:` in front matter, then the first `#` heading, then the
file name.

Notion uses a leading H1 as the page title, but only when it is the only H1 in the document. With a
second H1 anywhere, Notion keeps both, and the title appears twice. To make the result the same in
both cases, the leading H1 is removed from the body before sending. `--keep-h1` keeps it.

    --icon 🔒
    --icon ./logo.png
    --icon https://example.com/logo.png
    --cover ./banner.png
    --cover https://example.com/banner.jpg

An icon may be an emoji, an image URL, or a path to a local image. A cover may be an image URL or a
local path. Local files are uploaded to Notion. Notion's own gallery covers are ordinary URLs, so
you can paste one. Icons and covers can also come from front matter (`notion_icon:`,
`notion_cover:`) or from `.notion-publish.yml` (`icon:`, `cover:`). The flag wins.

`--dry-run` checks both without uploading anything.

## Republishing and the identity map

`notion-pages.yml` is the tool's record of which page each file became. The tool writes it; you
commit it. It lives at the repository root by default, and `--pages-file` overrides that.

```yaml
# Generated by notion-publish. Do not edit by hand.
# Maps each Markdown source to the Notion page it mirrors.
# To re-point an entry, delete it and publish again.
# Settings belong in .notion-publish.yml, which this tool never rewrites.
---
workspace_id: 5b1c...
pages:
  policies/access-control.md:
    id: 3cfab123-cd45-818b-9a72-c2bd16e85a62
    url: https://app.notion.com/p/Access-Control-Policy-3cfab123cd45818b9a72c2bd16e85a62
    parent:
      type: data_source_id
      id: 2efab123-cd45-8088-a1d3-000b41c7f38c
      name: Policies
    properties:
    - Function
    - Name
    - Owner
    flag_properties:
    - Owner
    title_override: Access Control
    source_sha256: 2b1f...
    properties_sha256: 77ad...
    flag_properties_sha256: 51e0...
    notion_sha256: 9c04...
    published_at: '2026-09-02T03:11:00Z'
```

The file holds page IDs, URLs, and hashes. It holds no credentials or page content. Keys are sorted
so that publishing one document changes one entry in the diff.

| Field                    | Meaning                                                             |
|--------------------------|---------------------------------------------------------------------|
| `properties`             | Every property the tool set, so it knows which ones it owns         |
| `flag_properties`        | The ones whose values came from `--property` or `--properties-json` |
| `title_override`         | The `--title` given, if any                                         |
| `keep_h1`                | Present when `--keep-h1` was given                                  |
| `source_sha256`          | Hash of the Markdown file                                           |
| `properties_sha256`      | Hash of the property values that came from the document             |
| `flag_properties_sha256` | Hash of the property values that came from flags                    |
| `notion_sha256`          | Hash of the page as Notion returned it after publishing             |

Flag-set property values are hashed but not stored. `republish` uses `flag_properties`,
`title_override`, and `keep_h1` to repeat what the last publish of each file did.

`--link` starts the file if it does not exist. Once it exists, every publish uses it. `--no-link`
ignores it and always creates a new page.

A publish with an entry does one of these:

| Output                   | What happened                                        |
|--------------------------|------------------------------------------------------|
| `Published ...`          | No entry: a new page was created                     |
| `Unchanged ...`          | Neither the file nor the properties changed          |
| `Updated ...`            | The file changed; body and properties were replaced  |
| `Updated properties ...` | Only the properties changed; the body was left alone |
| `(blocked)`              | The page was edited in Notion; nothing was written   |

Updating keeps the page's URL, so links to it keep working.

### Edits made in Notion

After each publish the tool reads the page back and records a hash of what Notion returns. Before
the next update it reads the page again. If the hash differs, someone edited the page in Notion, and
the tool stops with exit code 3 instead of overwriting their change. Look at the page, move the
change into the Markdown if you want to keep it, and publish again with `--force`.

If every page reports this at once, Notion probably changed how it renders Markdown. Nobody edited
them. `--force` is safe in that case.

### Pages removed from Notion

If an entry points at a page that no longer exists, the tool warns, forgets the entry, and creates a
new page.

### Child pages

Replacing a page body would delete any child page or database inside it. The tool refuses rather
than doing that.

## Publishing a set of files

Each run publishes one file, so a set of files is a shell loop:

    for f in policies/*.md; do
      notion-publish "$f" --link
    done
    notion-publish relink policies

Put the destination and shared properties in `.notion-publish.yml`, or pass them in the loop. The
loop is safe to re-run. An unchanged file costs one API call and reports `Unchanged`. A failure part
way through leaves the earlier files published and recorded, so running the loop again picks up
where it stopped. To stop at the first failure, add `|| break`.

`--property` is the highest layer, so a `--property` in the loop overrides the same property in
every file's front matter. If one document needs a different value, publish it separately or move
the property into front matter.

The identity map is locked while it is written, so parallel runs (`xargs -P`) do not lose entries.

Once the files are published, use `republish` to keep them current.

## Republishing everything

`republish` updates every page the identity map tracks, without naming files:

    notion-publish republish            # every entry in the map
    notion-publish republish policies   # only entries for files under policies/

Each file goes through the same checks as a single publish, and reports `Unchanged`, `Updated`,
`Updated properties`, or a problem. A summary line follows:

    12 documents: 10 unchanged, 1 updated, 1 changed in Notion

### What republish uses

Each page is updated where it already is, so no destination is needed. The recorded parent supplies
the schema. For each file, `republish` uses:

- the file's current Markdown and front matter
- `icon` and `cover` from front matter or `.notion-publish.yml`
- the `--title` and `--keep-h1` recorded from the last single-file publish

Options that describe one document or one destination are ignored, with a warning. They are
`--parent`, `--database`, `--property`, `--properties-json`, `--title`, `--icon`, `--cover`,
`--keep-h1`, `--link`, `--no-link`, `--page`, `--yes`, and `--local`. Changing a destination never
moves an existing page. `--no-upload`, `--force`, `--force-properties`, `--json`, and
`--pages-file` apply to every file.

### Properties set with flags

The values of properties set with `--property` or `--properties-json` are not recorded, so
`republish` cannot send them again. It leaves those properties alone. It does not set them and does
not clear them. Everything else follows the usual rules, so a property you add to or remove from
front matter is set or cleared.

To change a flag-set property, publish that file by name with the new flag. To hand a property over
to front matter, add it to front matter and publish the file once by name without the flag.

If `republish` has to recreate a page because the old one was deleted, the new page does not have
the flag-set properties. It warns and names them.

### Entries from older versions

Entries written before `flag_properties` was added do not say which properties came from flags.
`republish` updates such an entry only if the file's front matter produces exactly the properties
recorded last time. Otherwise it skips the file, explains why, and exits with code 3. Publish that
file once by name, with whatever flags it needs. That records the new fields, and `republish`
handles it from then on.

### Not included

- Files with no entry. Publishing a new document is something you do by name, once.
- Entries whose file is gone. They are reported, and their pages are left in Notion.
- `--dry-run`. Use `notion-publish status` to see what `republish` would do.

Links are rewritten as each page is written. Every tracked file already has a URL, so `republish`
does not need a `relink` pass.

A failure in one file is reported, and the rest still run. The exit code is 1 if anything failed, 3
if anything was blocked or skipped, and 0 otherwise.

`--force` applies to every file. Use it with `republish` only when every page reported as changed in
Notion should be overwritten, for example after Notion changes how it renders Markdown.

## Links between documents

A relative link such as `[Access Control](access-control.md)` means nothing in Notion. Worse, Notion
turns it into `https://access-control.md`, a link to a domain nobody owns. When an identity map is
in use, the tool rewrites each relative link to the Notion URL recorded for that file. Anchors
(`#section`) are kept.

A document that links to one not yet published cannot be rewritten on the first pass. The tool warns
about it. `relink` makes the second pass: it reads each recorded page, finds links in the
`https://<file>.md` form, and replaces them with the right URLs.

    notion-publish relink          # the whole repository
    notion-publish relink policies # the map found from that directory

`relink` also lists entries whose source file is gone. It does not remove their pages, because the
tool cannot tell a deleted file from a renamed one.

## Adopting pages that already exist

If a document is already in Notion, maybe published by hand or by another tool, publishing would
create a second copy. `adopt` records that the file and the existing page are the same document. It
changes neither one.

Name the page:

    notion-publish adopt policies/access-control.md \
      --page https://app.notion.com/p/Access-Control-Policy-3cfab123cd45818b9a72c2bd16e85a62

Or search by title in the destination the file would publish to:

    $ notion-publish adopt policies/access-control.md --parent Policies

    One page in "Policies" is titled "Access Control Policy":
      https://app.notion.com/p/Access-Control-Policy-3cfab123cd45818b9a72c2bd16e85a62
      last edited 2026-08-14 by Jane Doe

    Adopting means the next publish will replace that page's contents.
    Adopt it? [y/N]

Adopt stops and explains instead of guessing when:

- more than one page has the title (pass `--page` to choose)
- the file already has an entry (delete it from `notion-pages.yml` first to re-point it)
- no page has the title (publish instead)
- there is no terminal to ask, as in CI (pass `--yes`)

`--yes` accepts a title match without showing it. Use it only when you already know what will be
adopted.

Adopting does not publish. The next `notion-publish` run updates the page. That run always writes,
because adopting does not claim that the page already matches the file.

Title matching is a separate command because it is a guess. Everything else the tool does is exact:
an ID resolves or it does not, and a hash matches or it does not. Keeping the guess out of `publish`
means it never happens during an unattended run.

## Checking status

`status` compares every entry in the identity map with its file and its page, without writing
anything:

    $ notion-publish status
    /repo/notion-pages.yml -- 12 tracked

      changed locally    policies/access-control.md
      changed in Notion  policies/incident-response.md
                         https://app.notion.com/p/...
      never published    drafts/new-policy.md

    10 in sync, 1 changed locally, 1 changed in Notion, 1 never published

| State                    | Meaning                                 | Needs action |
|--------------------------|-----------------------------------------|--------------|
| in sync                  | Nothing to do                           | no           |
| changed locally          | The file changed since it was published | yes          |
| changed in Notion        | The page was edited in Notion           | yes          |
| changed in both          | Both                                    | yes          |
| page is gone from Notion | The page no longer exists in Notion     | yes          |
| no source file           | The file was deleted or moved           | yes          |
| never published          | A Markdown file with no entry           | no           |

It exits 3 if anything needs action, which makes it usable as a CI check. `--local` skips the calls
to Notion and compares file hashes only. `--json` prints one object per file.

## Local images

Notion's Markdown import only understands images at public URLs. A local path produces an empty
image block with no error, so a missing diagram looks like a successful publish.

`notion-publish` handles local images this way:

1. Each local image that is alone on its line is replaced with a placeholder paragraph.
2. The image file is uploaded to Notion.
3. The page is created or updated from the Markdown with placeholders.
4. Each placeholder is found, the image block is inserted after it, and the placeholder is deleted.

The rest of the document still goes through Notion's own parser. Uploads happen before the page is
touched, so a missing or oversized file fails without leaving a half-published page.

Alt text becomes the caption. Images inside code fences are ignored. An image in the middle of a
paragraph cannot become a block, because Notion has no inline images, so it is left alone and
reported. Images at `https://` URLs are passed through and must stay publicly reachable.

`--no-upload` skips uploading and warns about each image it leaves broken.

## What is changed before publishing

Notion parses CommonMark and GitHub-flavored Markdown well. Tables, nested lists, task lists, and
code fences all come through. There is one major exception, which the tool corrects.

**Soft line breaks.** In CommonMark, lines next to each other form one paragraph. Notion makes a
separate block of each line. A file wrapped at a fixed width would arrive double-spaced, and wrapped
list items would fall out of their list. The tool joins each paragraph, list item, and block quote
back into one line with spaces before sending. An explicit hard break (two trailing spaces, or a
trailing backslash) becomes `<br>`. Code fences and table rows are not touched.

The leading H1 is also removed, as described under [Title, icon, and cover](#title-icon-and-cover).

## Scripting and exit codes

| Code | Meaning                                     |
|------|---------------------------------------------|
| 0    | Published, updated, or nothing needed doing |
| 1    | Failed                                      |
| 2    | Usage error                                 |
| 3    | Stopped and needs a person (see below)      |
| 130  | Interrupted                                 |

Code 3 means a page was edited in Notion, `republish` skipped a file, or `status` found work to do.

`--json` prints one object per document on stdout. Messages go to stderr.

    {"source":"policies/access-control.md","action":"updated","id":"3cfab123-...",
     "url":"https://app.notion.com/p/...","parent":"2efab123-...","parent_name":"Policies"}

`action` is `created`, `updated`, `properties`, `unchanged`, `blocked`, or `skipped` (from
`republish`). `republish --json` prints no summary line.

The tool never waits for input when there is no terminal. Where it would ask a question, it fails
and names the flag that answers it.

## How Notion treats Markdown

These results were checked against the live API. Pipe tables become table blocks. Two-space nesting
becomes nested list items. Task lists become to-do blocks. Fenced code keeps its language. `---`
becomes a divider. Bold, italic, strikethrough, and inline code survive. H5 and H6 become heading 4,
as documented.

A block quote spread over several lines becomes one quote block per line, because Notion does not
join continuation lines. The soft-wrap fix above handles this.

## Known limits

- A new file has to be published once by name. `republish` covers only files already in the
  identity map.
- An image inside a paragraph cannot become a block.
- Files over 20 MB need Notion's multi-part upload, which is not implemented.
- `files` properties cannot be set.
- Page verification cannot be set or read through the API.
- H5 and H6 become heading 4.
- A bare `.md` file name in running text is auto-linked by Notion to a domain nobody owns. Only
  Markdown link targets are rewritten.
