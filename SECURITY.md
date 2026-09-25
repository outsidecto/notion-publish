# Security policy

## Reporting a vulnerability

Please report security problems privately, through
[GitHub's private vulnerability reporting](https://github.com/outsidecto/notion-publish/security/advisories/new),
rather than in a public issue.

## Supported versions

Only the latest release receives fixes.

## Handling of credentials

notion-publish reads a Notion API token from `NOTION_API_TOKEN` or `NOTION_API_KEY`, or from
`--token`. It sends the token only to `api.notion.com` and to the upload URL Notion returns. It
never writes the token to disk and never logs it, even with `-vvv`. `notion-publish-manifest.yml`
records page IDs, URLs, and content hashes, but it does not record credentials or page content.

`-vvv` prints shortened request and response bodies to stderr, and those include document content.
Leave it off in CI jobs whose logs are kept or shared.

Prefer the environment variable to `--token`, since command-line arguments are visible to other
users of the machine through the process list.
