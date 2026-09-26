# notion_publish

Many teams keep their important documents in Git, where changes get reviewed and every version is
kept. The people who read those documents often work in Notion instead. So somebody copies each
document over by hand, the two copies drift apart, and after a few months nobody can say which one
is current.

`notion_publish` is a command-line tool that publishes Markdown files from a Git repository into
Notion and then keeps those pages up to date. Git stays the authoritative copy. Notion shows a
current version of it.

It was built for a security and compliance corpus, where an auditor can reasonably ask which Notion
page corresponds to a given policy, and where "somebody pasted it in last spring" is not a good
answer.

## What it looks like

Publish a file. `--parent` takes a page ID, a Notion URL, or the exact name of a database:

    $ notion-publish policies/access-control.md --parent 'Policies' --link
    Published policies/access-control.md to database "Policies" (2efab123-...)
      https://app.notion.com/p/Access-Control-Policy-3cfab123cd45818b9a72c2bd16e85a62

`--link` writes a file called `notion-publish-manifest.yml`, which records the page each document
became. You commit that file. From then on, one command brings every page up to date:

    $ notion-publish republish
    Updated policies/incident-response.md to database "Policies" (2efab123-...)
      https://app.notion.com/p/Incident-Response-Policy-...
    12 documents: 11 unchanged, 1 updated

Before publishing anything, you can ask what has moved apart:

    $ notion-publish status
    /repo/notion-publish-manifest.yml -- 12 tracked

    Changed locally (1)
      policies/access-control.md

    Changed in Notion (1)
      policies/incident-response.md
        https://app.notion.com/p/...

    10 in sync, 1 changed locally, 1 changed in Notion

`status` exits with code 3 when something needs a person to look at it, so it also works as a check
in continuous integration.

## The parts that are easy to get wrong

- **Updating instead of duplicating.** Because the manifest records which page each file became,
  publishing again replaces that page's contents and keeps its URL. Links people have already
  shared keep working.
- **Edits made in Notion.** The tool records what Notion returned after each publish and reads the
  page again before the next one. If somebody edited the page, it stops and says so rather than
  overwriting their work.
- **Pages deleted in Notion.** Deleting a page in Notion moves it to the trash, where the API still
  returns it with all its content. The tool notices the difference and publishes a fresh page.
- **Database properties.** Values are checked against the live database schema before anything is
  written, so a misspelled select option is an error instead of a brand-new option added to your
  schema. Properties the tool set before and no longer sets are cleared; properties it never set are
  left alone.
- **Links between documents.** A relative link to another Markdown file does not merely break in
  Notion. Notion turns it into a link to a domain nobody owns. Links to published documents are
  rewritten to their Notion URLs.
- **Local images.** Notion's Markdown import only understands images at public URLs, and a local
  path produces an empty image block with no error at all. Local images are uploaded and placed as
  real image blocks.
- **Hard-wrapped text.** Notion makes a separate block out of each line, so a file wrapped at a
  column width arrives looking double-spaced. Wrapped paragraphs and list items are joined back
  together first.

## Why another gem

Notion does not publish an official Ruby SDK. The client it maintains is for JavaScript.

Ruby has a dozen unofficial Notion gems, and they address two different problems. Most are API
clients that wrap the HTTP endpoints, and the widely used ones have not seen a release in some time:
`notion-ruby-client` last shipped in October 2023, `notion-sdk-ruby` in June 2022, and `notion` in
January 2021. Notion reorganized its data model in September 2025, when a database became a
container holding one or more data sources, and the schema and rows moved to the data source. A
client written before that models an API that no longer works the same way.

The gems that do handle Markdown run in the other direction. `notion_to_md` exports pages from
Notion into Markdown, and `notion_rails` renders Notion blocks as HTML inside a Rails application.
Both are useful. Neither publishes into Notion, and neither keeps a record of what was published,
which is the part that makes a second run safe instead of duplicating everything.

The conversion works differently here as well. Tools in this area usually build Notion's block JSON
themselves, which means carrying a Markdown parser and keeping it in step with Notion's block types.
`notion_publish` sends the Markdown and lets Notion parse it, using the Markdown parameter Notion's
own API accepts. Tables, nested lists, task lists, and fenced code arrive correctly because Notion
did that work. It is also why the gem has no runtime dependencies at all: the client is `Net::HTTP`
from the Ruby standard library.

## Getting it

Requires Ruby 3.2 or later.

    gem install notion_publish

The source code, the full usage reference, and the issue tracker are on GitHub:
[github.com/outsidecto/notion-publish](https://github.com/outsidecto/notion-publish).

MIT licensed. This project is not affiliated with or endorsed by Notion Labs, Inc.
