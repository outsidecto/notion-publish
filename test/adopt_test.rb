# frozen_string_literal: true

require "test_helper"

# Adopting records that a local file and an existing Notion page are the same
# document. It changes neither, and it never guesses without saying so.
class AdoptTest < Minitest::Test
  PAGE = "3cfab123-cd45-818b-9a72-c2bd16e85a62"
  URL = "https://app.notion.com/p/Access-Control-Policy-3cfab123cd45818b9a72c2bd16e85a62"
  DS = "2efab123-cd45-8088-a1d3-000b41c7f38c"
  UUID = "32dab123-cd45-803f-94c2-d29516bd0188"

  def setup
    stub_me
    stub_notion(:get, "/v1/pages/#{PAGE}", status: 200, body: page_body)
    stub_request(:get, "#{StubbingHelpers::API}/v1/pages/#{PAGE}/markdown")
      .to_return(status: 200, body: JSON.generate("markdown" => "existing content"))
    stub_notion(:get, "/v1/users/u1", status: 200, body: { "name" => "Jane Doe" })
  end

  # Naming the page is exact: nothing is searched and nothing is confirmed.
  def test_adopting_by_page_url_records_the_entry
    with_doc do |path, pages|
      code, out, = run_cli(["adopt", path, "--page", URL, "--pages-file", pages])

      assert_equal NotionPublish::CLI::OK, code
      assert_includes out, "Adopted"
      assert_includes out, "Run notion-publish to update it."

      entry = NotionPublish::PageMap.new(pages).entry(path)

      assert_equal PAGE, entry.id
      assert_equal URL, entry.url
    end
  end

  # Adoption asserts identity, not that the page already holds this content, so
  # the next publish must run rather than reporting the document unchanged.
  def test_adopting_does_not_record_the_source_hash
    with_doc do |path, pages|
      run_cli(["adopt", path, "--page", URL, "--pages-file", pages])
      entry = NotionPublish::PageMap.new(pages).entry(path)

      assert_nil entry.source_sha256
      assert_equal Digest::SHA256.hexdigest("existing content"), entry.notion_sha256,
                   "the page's current content is recorded, so a later edit is still detected"
    end
  end

  def test_a_page_that_cannot_be_reached_is_reported
    stub_missing(:get, "/v1/pages/#{PAGE}", PAGE)

    with_doc do |path, pages|
      code, _, err = run_cli(["adopt", path, "--page", URL, "--pages-file", pages])

      assert_equal NotionPublish::CLI::FAILURE, code
      assert_includes err, "Cannot reach"
    end
  end

  def test_an_already_adopted_file_is_refused
    with_doc do |path, pages|
      run_cli(["adopt", path, "--page", URL, "--pages-file", pages])

      code, _, err = run_cli(["adopt", path, "--page", URL, "--pages-file", pages])

      assert_equal NotionPublish::CLI::FAILURE, code
      assert_includes err, "already points at a page"
      assert_includes err, "Delete that entry"
    end
  end

  # A title search with no terminal must fail naming the flag, not hang.
  def test_a_title_match_without_a_terminal_names_the_flag
    stub_target
    stub_query([page_body])

    with_doc do |path, pages|
      code, _, err = run_cli(["adopt", path, "--parent", UUID, "--pages-file", pages])

      assert_equal NotionPublish::CLI::FAILURE, code
      assert_includes err, "no terminal here to confirm"
      assert_includes err, "--yes"
      assert_includes err, "--page"
    end
  end

  def test_yes_accepts_a_single_title_match
    stub_target
    stub_query([page_body])

    with_doc do |path, pages|
      code, out, = run_cli(["adopt", path, "--parent", UUID, "--pages-file", pages, "--yes"])

      assert_equal NotionPublish::CLI::OK, code
      assert_includes out, "Adopted"
      assert_equal PAGE, NotionPublish::PageMap.new(pages).entry(path).id
    end
  end

  def test_a_title_match_is_confirmed_at_a_terminal
    stub_target
    stub_query([page_body])

    with_doc do |path, pages|
      code, out, = run_cli(["adopt", path, "--parent", UUID, "--pages-file", pages], stdin: terminal("y\n"))

      assert_equal NotionPublish::CLI::OK, code
      assert_includes out, "last edited 2026-08-14 by Jane Doe"
      assert_includes out, "Adopt it? [y/N]"
      assert_equal PAGE, NotionPublish::PageMap.new(pages).entry(path).id
    end
  end

  def test_declining_at_the_terminal_writes_nothing
    stub_target
    stub_query([page_body])

    with_doc do |path, pages|
      code, = run_cli(["adopt", path, "--parent", UUID, "--pages-file", pages], stdin: terminal("\n"))

      assert_equal NotionPublish::CLI::FAILURE, code
      refute_path_exists pages
    end
  end

  def test_more_than_one_match_refuses_and_lists_them
    stub_target
    stub_query([page_body, page_body(id: "other", url: "https://n/p/other")])

    with_doc do |path, pages|
      code, _, err = run_cli(["adopt", path, "--parent", UUID, "--pages-file", pages, "--yes"])

      assert_equal NotionPublish::CLI::FAILURE, code
      assert_includes err, "More than one page"
      assert_includes err, "https://n/p/other"
      assert_includes err, "--page"
    end
  end

  def test_no_match_says_to_publish_instead
    stub_target
    stub_query([])

    with_doc do |path, pages|
      code, _, err = run_cli(["adopt", path, "--parent", UUID, "--pages-file", pages, "--yes"])

      assert_equal NotionPublish::CLI::FAILURE, code
      assert_includes err, "Nothing to adopt"
      assert_includes err, "notion-publish <file>"
    end
  end

  def test_adopt_requires_exactly_one_file
    code, _, err = run_cli(["adopt"])

    assert_equal NotionPublish::CLI::USAGE, code
    assert_includes err, "one Markdown file to adopt"
  end

  private

  def terminal(input)
    StringIO.new(input).tap { |io| io.define_singleton_method(:tty?) { true } }
  end

  def page_body(id: PAGE, url: URL)
    {
      "object" => "page", "id" => id, "url" => url,
      "last_edited_time" => "2026-08-14T10:00:00.000Z",
      "last_edited_by" => { "object" => "user", "id" => "u1" },
      "properties" => { "Company Information" => { "type" => "title",
                                                   "title" => rich("Access Control Policy") } }
    }
  end

  def stub_target
    stub_notion(:get, "/v1/blocks/#{UUID}", status: 200, body: {
                  "object" => "block", "id" => UUID, "type" => "child_database",
                  "child_database" => { "title" => "References" }
                })
    stub_notion(:get, "/v1/databases/#{UUID}", status: 200, body: {
                  "object" => "database", "id" => UUID, "title" => rich("References"), "is_inline" => false,
                  "data_sources" => [{ "id" => DS, "name" => "References" }]
                })
    stub_notion(:get, "/v1/data_sources/#{DS}", status: 200, body: {
                  "object" => "data_source", "id" => DS, "title" => rich("References"),
                  "properties" => { "Company Information" => { "id" => "title", "type" => "title", "title" => {} } }
                })
  end

  def stub_query(results)
    stub_request(:post, "#{StubbingHelpers::API}/v1/data_sources/#{DS}/query")
      .to_return(status: 200, body: JSON.generate("results" => results))
  end

  def with_doc
    Dir.mktmpdir do |dir|
      path = File.join(dir, "access-control-policy.md")
      File.write(path, "# Access Control Policy\n\nBody.\n")
      yield path, File.join(dir, "notion-pages.yml")
    end
  end
end
