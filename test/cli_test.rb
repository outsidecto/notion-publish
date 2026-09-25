# frozen_string_literal: true

require "test_helper"

class CLITest < Minitest::Test
  UUID = "32dab123-cd45-803f-94c2-d29516bd0188"
  DS = "2efab123-cd45-8088-a1d3-000b41c7f38c"

  def test_missing_file_argument_is_a_usage_error
    code, _, err = run_cli([])

    assert_equal NotionPublish::CLI::USAGE, code
    assert_includes err, "No Markdown file given"
    assert_includes err, "Usage: notion-publish"
  end

  def test_more_than_one_file_is_a_usage_error
    code, _, err = run_cli(%w[a.md b.md])

    assert_equal NotionPublish::CLI::USAGE, code
    assert_includes err, "one Markdown file at a time"
  end

  # Notion needs a parent for every page and an internal connection cannot
  # create one at the workspace root, so this must fail before any request.
  def test_no_destination_explains_why_one_is_required
    with_markdown("# Hello\n") do |path|
      code, _, err = run_cli([path])

      assert_equal NotionPublish::CLI::FAILURE, code
      assert_includes err, "No destination"
      assert_includes err, "--parent"
      assert_includes err, "--database"
    end
  end

  def test_dry_run_resolves_without_writing
    stub_me(name: "Security and Compliance Publishing")
    stub_block(UUID, "child_database", "title" => "Policies")
    stub_notion(:get, "/v1/databases/#{UUID}", status: 200, body: {
                  "object" => "database", "id" => UUID, "title" => rich("Policies"), "is_inline" => false,
                  "data_sources" => [{ "id" => UUID, "name" => "Policies" }]
                })

    with_markdown("# Quarterly Review\n\nBody.\n") do |path|
      code, out, = run_cli([path, "--parent", UUID, "--dry-run"])

      assert_equal NotionPublish::CLI::OK, code
      assert_includes out, "Would publish"
      assert_includes out, "Policies"
      assert_includes out, "\"Quarterly Review\""
    end

    assert_not_requested :post, "#{StubbingHelpers::API}/v1/pages"
  end

  def test_front_matter_supplies_the_parent
    stub_me
    stub_block(UUID, "child_page", "title" => "Docs")

    with_markdown("---\ntitle: From Front Matter\nnotion_parent: #{UUID}\n---\n\nBody.\n") do |path|
      code, out, = run_cli([path, "--dry-run"])

      assert_equal NotionPublish::CLI::OK, code
      assert_includes out, "\"From Front Matter\""
    end
  end

  def test_explicit_parent_beats_front_matter
    stub_me
    stub_block(UUID, "child_page", "title" => "Chosen")

    with_markdown("---\nnotion_parent: aaaaaaaabbbbccccddddeeeeeeeeeeee\n---\n# T\n") do |path|
      code, out, = run_cli([path, "--parent", UUID, "--dry-run"])

      assert_equal NotionPublish::CLI::OK, code
      assert_includes out, "Chosen"
    end
  end

  def test_title_falls_back_to_the_filename_when_there_is_no_heading
    stub_me
    stub_block(UUID, "child_page", "title" => "Docs")

    with_markdown("Just a paragraph.\n", name: "release-notes.md") do |path|
      _, out, = run_cli([path, "--parent", UUID, "--dry-run"])

      assert_includes out, "\"release-notes\""
    end
  end

  def test_whoami_reports_the_credential_kind
    stub_me(name: "Security and Compliance Publishing")

    code, out, = run_cli(["--whoami"])

    assert_equal NotionPublish::CLI::OK, code
    assert_includes out, "Security and Compliance Publishing"
    assert_includes out, "internal connection owned by the workspace"
  end

  def test_missing_token_is_reported_before_anything_else
    with_markdown("# Hello\n") do |path|
      code, _, err = run_cli([path, "--parent", UUID], token: nil)

      assert_equal NotionPublish::CLI::FAILURE, code
      assert_includes err, "No Notion API token found"
      assert_includes err, "NOTION_API_TOKEN"
    end
  end

  # --- properties ---------------------------------------------------------

  def test_dry_run_validates_properties_against_the_schema
    stub_database_target

    with_markdown("# Quarterly Review\n") do |path|
      code, out, = run_cli([path, "--parent", UUID, "-n",
                            "--property", "Function=Operations",
                            "--property", "Function=Security and Compliance"])

      assert_equal NotionPublish::CLI::OK, code
      assert_includes out, %(Function: ["Operations", "Security and Compliance"])
      assert_includes out, %(Company Information: "Quarterly Review")
    end
  end

  # A typo must fail before anything is written, because Notion would create the
  # option rather than reject it.
  def test_dry_run_refuses_an_unknown_option
    stub_database_target

    with_markdown("# T\n") do |path|
      code, out, err = run_cli([path, "--parent", UUID, "-n", "--property", "Function=Opperations"])

      assert_equal NotionPublish::CLI::FAILURE, code
      assert_includes err, "no option named"
      # Nothing may be announced before validation succeeds.
      refute_includes out, "Would publish"
    end
    assert_not_requested :post, "#{StubbingHelpers::API}/v1/pages"
  end

  def test_properties_json_is_accepted
    stub_database_target

    with_markdown("# T\n") do |path|
      code, out, = run_cli([path, "--parent", UUID, "-n",
                            "--properties-json", '{"Function": ["Legal"], "Due Date": "2026-09-15"}'])

      assert_equal NotionPublish::CLI::OK, code
      assert_includes out, %(Function: ["Legal"])
      assert_includes out, "Due Date: 2026-09-15\n"
    end
  end

  def test_a_property_flag_overrides_properties_json
    stub_database_target

    with_markdown("# T\n") do |path|
      _, out, = run_cli([path, "--parent", UUID, "-n",
                         "--properties-json", '{"Function": ["Legal"]}',
                         "--property", "Function=Operations"])

      assert_includes out, %(Function: ["Operations"])
    end
  end

  def test_front_matter_properties_are_used
    stub_database_target

    front = "---\nproperties:\n  Function: [Legal, Operations]\n---\n# T\n"
    with_markdown(front) do |path|
      _, out, = run_cli([path, "--parent", UUID, "-n"])

      assert_includes out, %(Function: ["Legal", "Operations"])
    end
  end

  def test_publishing_sends_the_built_properties
    stub_database_target
    stub_request(:post, "#{StubbingHelpers::API}/v1/pages")
      .to_return(status: 200, body: JSON.generate("object" => "page", "id" => "new", "url" => "https://n/p/new"))

    with_markdown("# Quarterly Review\n\nBody.\n") do |path|
      code, out, = run_cli([path, "--parent", UUID, "--property", "Function=Legal"])

      assert_equal NotionPublish::CLI::OK, code
      assert_includes out, "https://n/p/new"
    end

    assert_requested(:post, "#{StubbingHelpers::API}/v1/pages") do |req|
      body = JSON.parse(req.body)
      body["parent"] == { "data_source_id" => DS } &&
        # The leading H1 became the title, so it is no longer in the body.
        !body["markdown"].include?("# Quarterly Review") &&
        body["markdown"].include?("Body.") &&
        body.dig("properties", "Function", "multi_select") == [{ "name" => "Legal" }] &&
        body.dig("properties", "Company Information", "title", 0, "text", "content") == "Quarterly Review"
    end
  end

  def test_properties_subcommand_prints_the_schema
    stub_database_target

    code, out, = run_cli(["properties", "--parent", UUID])

    assert_equal NotionPublish::CLI::OK, code
    assert_includes out, "Company Information"
    assert_includes out, "multi_select"
    assert_includes out, "Operations | Security and Compliance"
    assert_includes out, "(read-only)"
  end

  # A dry run must reject a bad icon rather than print it, and must not upload.
  def test_dry_run_rejects_a_bad_icon
    stub_me
    stub_block(UUID, "child_page", "title" => "Page")

    with_markdown("# T\n") do |path|
      code, out, err = run_cli([path, "--parent", UUID, "-n", "--icon", "padlock"])

      assert_equal NotionPublish::CLI::FAILURE, code
      assert_includes err, "not an emoji, a URL, or a path"
      refute_includes out, "Would publish"
    end
    assert_not_requested :post, "#{StubbingHelpers::API}/v1/file_uploads"
  end

  def test_dry_run_reports_a_valid_icon_and_cover
    stub_me
    stub_block(UUID, "child_page", "title" => "Page")

    with_markdown("# T\n") do |path|
      code, out, = run_cli([path, "--parent", UUID, "-n", "--icon", "🔒",
                            "--cover", "https://app.notion.com/images/page-cover/artemis_ii_4.jpg"])

      assert_equal NotionPublish::CLI::OK, code
      assert_includes out, "icon: 🔒"
      assert_includes out, "cover: https://app.notion.com/images/page-cover/artemis_ii_4.jpg"
    end
  end

  # Exit code 3 means "needs a human", so CI can gate a merge on it without
  # treating it as a crash.
  def test_drift_exits_with_the_blocked_code_and_json_says_so
    stub_database_target
    stub_request(:post, "#{StubbingHelpers::API}/v1/pages")
      .to_return(status: 200, body: JSON.generate("object" => "page", "id" => "pg", "url" => "https://n/p/pg"))
    stub_request(:get, "#{StubbingHelpers::API}/v1/pages/pg")
      .to_return(status: 200, body: JSON.generate("object" => "page", "id" => "pg", "url" => "https://n/p/pg"))
    stub_request(:get, "#{StubbingHelpers::API}/v1/pages/pg/markdown")
      .to_return(status: 200, body: JSON.generate("markdown" => "as published"))
    stub_request(:patch, %r{/v1/pages/pg}).to_return(status: 200, body: JSON.generate("object" => "page"))

    Dir.mktmpdir do |dir|
      path = File.join(dir, "doc.md")
      File.write(path, "# T\n\nOne.\n")
      pages = File.join(dir, "notion-publish-manifest.yml")

      assert_equal NotionPublish::CLI::OK,
                   run_cli([path, "--parent", UUID, "--link", "--manifest", pages]).first

      File.write(path, "# T\n\nTwo.\n")
      stub_request(:get, "#{StubbingHelpers::API}/v1/pages/pg/markdown")
        .to_return(status: 200, body: JSON.generate("markdown" => "somebody edited this"))

      code, out, err = run_cli([path, "--parent", UUID, "--link", "--manifest", pages, "--json"])

      assert_equal NotionPublish::CLI::BLOCKED, code
      assert_includes err, "changed in Notion"
      assert_equal "blocked", JSON.parse(out)["action"]
    end
  end

  def test_json_reports_the_action_and_url
    stub_database_target
    stub_request(:post, "#{StubbingHelpers::API}/v1/pages")
      .to_return(status: 200, body: JSON.generate("object" => "page", "id" => "pg", "url" => "https://n/p/pg"))

    with_markdown("# T\n") do |path|
      code, out, = run_cli([path, "--parent", UUID, "--json"])

      assert_equal NotionPublish::CLI::OK, code
      row = JSON.parse(out)

      assert_equal "created", row["action"]
      assert_equal "https://n/p/pg", row["url"]
      assert_equal path, row["source"]
    end
  end

  # Front matter written for a database should not block publishing the same
  # document under a page; an explicit flag still fails.
  def test_page_parent_skips_document_properties_with_a_warning
    stub_me
    stub_block(UUID, "child_page", "title" => "Security and Compliance (S&C)")

    with_markdown("---\nproperties:\n  Function: [Legal]\n---\n# T\n") do |path|
      code, out, err = run_cli([path, "--parent", UUID, "-n"])

      assert_equal NotionPublish::CLI::OK, code
      assert_includes err, "Skipped \"Function\""
      assert_includes out, "Would publish"
    end
  end

  def test_page_parent_rejects_an_explicit_property
    stub_me
    stub_block(UUID, "child_page", "title" => "Security and Compliance (S&C)")

    with_markdown("# T\n") do |path|
      code, _, err = run_cli([path, "--parent", UUID, "-n", "--property", "Function=Legal"])

      assert_equal NotionPublish::CLI::FAILURE, code
      assert_includes err, "page parent accepts only a title"
    end
  end

  def test_help_prints_usage_and_succeeds
    code, out, = run_cli(["--help"])

    assert_equal NotionPublish::CLI::OK, code
    assert_includes out, "Usage: notion-publish"
  end

  def test_jobs_outside_the_allowed_range_is_a_usage_error
    code, _, err = run_cli(%w[status --jobs 0])

    assert_equal NotionPublish::CLI::USAGE, code
    assert_includes err, "--jobs must be between 1 and 10"
  end

  def test_version_prints_the_version
    code, out, = run_cli(["--version"])

    assert_equal NotionPublish::CLI::OK, code
    assert_equal "notion-publish #{NotionPublish::VERSION}\n", out
  end

  # ApiError is a subclass of Error. The restricted-resource explanation is only
  # reachable if the more specific rescue comes first.
  def test_a_restricted_connection_is_explained
    stub_database_target
    stub_notion(:post, "/v1/pages", status: 403, body: {
                  "object" => "error", "status" => 403, "code" => "restricted_resource",
                  "message" => "Insufficient permissions for this endpoint."
                })

    with_markdown("# Hello\n") do |path|
      code, _, err = run_cli([path, "--parent", UUID])

      assert_equal NotionPublish::CLI::FAILURE, code
      assert_includes err, "\"Test Connection\" is not allowed to do that (restricted_resource)"
      assert_includes err, "Insert content"
    end
  end

  def test_an_interrupt_exits_with_the_shell_convention
    cli = NotionPublish::CLI.new(stdout: StringIO.new, stderr: StringIO.new, client: client)
    cli.define_singleton_method(:dispatch) { |*| raise Interrupt }

    assert_equal NotionPublish::CLI::INTERRUPTED, cli.run(%w[status])
  end

  private

  def stub_database_target
    stub_me
    stub_block(UUID, "child_database", "title" => "Policies")
    stub_notion(:get, "/v1/databases/#{UUID}", status: 200, body: {
                  "object" => "database", "id" => UUID, "title" => rich("Policies"),
                  "is_inline" => false, "data_sources" => [{ "id" => DS, "name" => "Policies" }]
                })
    stub_notion(:get, "/v1/data_sources/#{DS}", status: 200, body: {
                  "object" => "data_source", "id" => DS, "title" => rich("Policies"),
                  "properties" => {
                    "Company Information" => { "id" => "title", "type" => "title", "title" => {} },
                    "Function" => { "id" => "f", "type" => "multi_select", "multi_select" => {
                      "options" => [{ "name" => "Operations" }, { "name" => "Security and Compliance" },
                                    { "name" => "Legal" }]
                    } },
                    "Due Date" => { "id" => "d", "type" => "date", "date" => {} },
                    "Last edited by" => { "id" => "e", "type" => "last_edited_by", "last_edited_by" => {} }
                  }
                })
  end
end
