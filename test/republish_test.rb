# frozen_string_literal: true

require "test_helper"

# Republishing every tracked document from what its entry recorded.
class RepublishTest < Minitest::Test
  PAGE = "3cfab123-cd45-81fb-9c4d-f11bd6f8272a"
  DS = "2efab123-cd45-8088-a1d3-000b41c7f38c"
  API = StubbingHelpers::API

  def setup
    stub_me
    stub_schema
    stub_request(:post, "#{API}/v1/pages")
      .to_return(status: 200, body: JSON.generate("object" => "page", "id" => PAGE, "url" => "https://n/p/x"))
    stub_request(:get, "#{API}/v1/pages/#{PAGE}")
      .to_return(status: 200, body: JSON.generate("object" => "page", "id" => PAGE, "url" => "https://n/p/x"))
    stub_request(:get, "#{API}/v1/pages/#{PAGE}/markdown")
      .to_return(status: 200, body: JSON.generate("object" => "page_markdown", "markdown" => "Body."))
    @replaced = stub_request(:patch, "#{API}/v1/pages/#{PAGE}/markdown")
                .to_return(status: 200, body: JSON.generate("object" => "page_markdown"))
    @patched = stub_request(:patch, "#{API}/v1/pages/#{PAGE}")
               .to_return(status: 200, body: JSON.generate("object" => "page", "id" => PAGE, "url" => "https://n/p/x"))
  end

  def test_unchanged_documents_are_listed_with_v_and_nothing_is_written
    with_published do |dir|
      code, out, = run_cli(["republish", dir, "-v"])

      assert_equal NotionPublish::CLI::OK, code
      assert_includes out, "Unchanged doc.md"
      assert_includes out, "1 document: 1 unchanged"
      assert_not_requested @replaced
      assert_not_requested @patched
    end
  end

  def test_unchanged_documents_are_left_out_by_default
    with_published do |dir|
      _, out, = run_cli(["republish", dir])

      refute_includes out, "Unchanged"
      assert_includes out, "1 document: 1 unchanged"
    end
  end

  # Progress is for people at a terminal. Tests, pipes, and CI have none.
  def test_progress_appears_only_on_a_terminal
    with_published do |dir|
      _, _, err = run_cli(["republish", dir])

      refute_includes err, "Checking"

      tty = StringIO.new.tap { |io| io.define_singleton_method(:tty?) { true } }
      cli = NotionPublish::CLI.new(stdout: StringIO.new, stderr: tty, client: client)
      cli.run(["republish", dir])

      assert_includes tty.string, "Checking 1/1  doc.md"
      assert tty.string.end_with?("\r\e[K"), "and the line is cleared at the end"
    end
  end

  def test_a_changed_document_is_updated_in_place
    with_published do |dir, path|
      File.write(path, "# Title\n\nRewritten.\n")

      code, out, = run_cli(["republish", dir])

      assert_equal NotionPublish::CLI::OK, code
      assert_includes out, "Updated doc.md"
      assert_requested @replaced
    end
  end

  # Their values were never recorded, so republish must neither resend nor
  # clear them.
  def test_properties_set_with_flags_are_left_alone
    with_published(properties: ["Function=Legal"]) do |dir, path|
      File.write(path, "# Title\n\nRewritten.\n")

      run_cli(["republish", dir])

      assert_requested(:patch, "#{API}/v1/pages/#{PAGE}") do |req|
        sent = JSON.parse(req.body)["properties"]
        !sent.key?("Function") && sent.key?("Company Information")
      end
    end
  end

  def test_front_matter_properties_are_applied
    with_published(body: "---\nproperties:\n  Status: Active\n---\n# Title\n\nBody.\n") do |dir, path|
      File.write(path, "---\nproperties:\n  Status: Draft\n---\n# Title\n\nBody.\n")

      run_cli(["republish", dir])

      assert_requested(:patch, "#{API}/v1/pages/#{PAGE}") do |req|
        JSON.parse(req.body).dig("properties", "Status", "select", "name") == "Draft"
      end
    end
  end

  def test_a_recorded_title_override_is_reused
    with_published(title: "Chosen Title") do |dir, path|
      File.write(path, "# Title\n\nRewritten.\n")

      run_cli(["republish", dir])

      assert_requested(:patch, "#{API}/v1/pages/#{PAGE}") do |req|
        JSON.parse(req.body).dig("properties", "Company Information", "title", 0, "text", "content") ==
          "Chosen Title"
      end
    end
  end

  def test_a_recorded_keep_h1_is_reused
    with_published(keep_h1: true) do |dir, path|
      File.write(path, "# Title\n\nRewritten.\n")

      run_cli(["republish", dir])

      assert_requested(:patch, "#{API}/v1/pages/#{PAGE}/markdown") do |req|
        JSON.parse(req.body).dig("replace_content", "new_str").start_with?("# Title")
      end
    end
  end

  # An entry from before flag-set properties were recorded is republished
  # only when front matter reproduces what it was given.
  def test_an_older_entry_that_front_matter_reproduces_is_republished_and_upgraded
    with_published do |dir, path, map|
      downgrade(map, path)
      File.write(path, "# Title\n\nRewritten.\n")

      code, = run_cli(["republish", dir])

      assert_equal NotionPublish::CLI::OK, code
      assert_equal [], NotionPublish::Manifest.new(map.path).entry(path).flag_properties
    end
  end

  def test_an_older_entry_that_front_matter_cannot_reproduce_is_skipped
    with_published(properties: ["Function=Legal"]) do |dir, path, map|
      downgrade(map, path)
      File.write(path, "# Title\n\nRewritten.\n")

      code, _, err = run_cli(["republish", dir])

      assert_equal NotionPublish::CLI::BLOCKED, code
      assert_includes err, "Skipped doc.md"
      assert_includes err, "Publish this file on its own once"
      assert_not_requested @replaced
    end
  end

  def test_a_page_edited_in_notion_blocks_that_document
    with_published do |dir, path|
      File.write(path, "# Title\n\nRewritten.\n")
      stub_request(:get, "#{API}/v1/pages/#{PAGE}/markdown")
        .to_return(status: 200, body: JSON.generate("markdown" => "Someone edited this."))

      code, _, err = run_cli(["republish", dir])

      assert_equal NotionPublish::CLI::BLOCKED, code
      assert_includes err, "has changed in Notion"
      assert_not_requested @replaced
    end
  end

  # An adopted entry records no parent, so republish asks Notion. A page moved
  # under a heading has that heading block as its parent, not a page.
  def test_an_adopted_page_under_a_heading_finds_the_page_above_it
    with_published do |dir, path, map|
      raw = map.entry(path).to_h.except("parent", "source_sha256")
      map.pages[map.key_for(path)] = raw
      map.save
      stub_request(:get, "#{API}/v1/pages/#{PAGE}").to_return(status: 200, body: JSON.generate(
        "object" => "page", "id" => PAGE, "url" => "https://n/p/x",
        "parent" => { "type" => "block_id", "block_id" => "aaaaaaaa-0000-0000-0000-000000000001" }
      ))
      stub_notion(:get, "/v1/blocks/aaaaaaaa-0000-0000-0000-000000000001", status: 200, body: {
                    "object" => "block", "id" => "aaaaaaaa-0000-0000-0000-000000000001", "type" => "heading_2",
                    "parent" => { "type" => "page_id", "page_id" => "bbbbbbbb-0000-0000-0000-000000000002" }
                  })
      stub_notion(:get, "/v1/blocks/bbbbbbbb-0000-0000-0000-000000000002", status: 200, body: {
                    "object" => "block", "id" => "bbbbbbbb-0000-0000-0000-000000000002", "type" => "child_page",
                    "child_page" => { "title" => "Policies" }
                  })

      code, out, err = run_cli(["republish", dir])

      assert_equal NotionPublish::CLI::OK, code, err
      assert_includes out, "Updated doc.md to page \"Policies\""
    end
  end

  # Publishing one tracked file by name needs no destination: the entry
  # already says where its page is.
  def test_a_tracked_file_can_be_published_by_name_without_a_destination
    with_published do |_dir, path|
      stub_request(:get, "#{API}/v1/pages/#{PAGE}/markdown")
        .to_return(status: 200, body: JSON.generate("markdown" => "Someone added a sentence."))

      code, out, err = run_cli([path, "--force"])

      assert_equal NotionPublish::CLI::OK, code, err
      assert_includes out, "Updated #{path}"
      assert_requested @replaced
    end
  end

  def test_a_destination_is_ignored_with_a_warning
    with_published do |dir|
      code, _, err = run_cli(["republish", dir, "--parent", "Elsewhere", "--title", "X"])

      assert_equal NotionPublish::CLI::OK, code
      assert_includes err, "Ignoring --parent, --title"
    end
  end

  def test_dry_run_points_to_status
    code, _, err = run_cli(%w[republish --dry-run])

    assert_equal NotionPublish::CLI::USAGE, code
    assert_includes err, "notion-publish status"
  end

  def test_a_missing_source_file_is_reported_and_does_not_fail_the_run
    with_published do |dir, path|
      File.delete(path)

      code, _, err = run_cli(["republish", dir])

      assert_equal NotionPublish::CLI::OK, code
      assert_includes err, "Skipped doc.md: no source file"
    end
  end

  def test_only_entries_under_the_directory_are_republished
    with_published do |dir|
      FileUtils.mkdir_p(File.join(dir, "other"))

      _, out, = run_cli(["republish", File.join(dir, "other"), "--manifest",
                         File.join(dir, "notion-publish-manifest.yml")])

      refute_includes out, "doc.md"
      assert_includes out, "0 documents"
    end
  end

  def test_json_includes_files_that_never_reached_notion
    with_published do |dir, path|
      File.delete(path)

      _, out, = run_cli(["republish", dir, "--json"])

      assert_equal({ "source" => "doc.md", "action" => "orphaned" }, JSON.parse(out.lines.first))
    end
  end

  def test_a_failure_is_reported_and_fails_the_run
    with_published do |dir, path|
      File.write(path, "# Title\n\nRewritten.\n")
      failure = { "code" => "internal_server_error", "message" => "boom" }
      stub_notion(:patch, "/v1/pages/#{PAGE}/markdown", status: 500, body: failure)

      code, _, err = run_cli(["republish", dir])

      assert_equal NotionPublish::CLI::FAILURE, code
      assert_includes err, "Failed doc.md"
    end
  end

  private

  def with_published(body: "# Title\n\nBody.\n", properties: [], title: nil, keep_h1: false)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "doc.md")
      File.write(path, body)
      map = NotionPublish::Manifest.new(File.join(dir, NotionPublish::Manifest::FILENAME))
      NotionPublish::Publisher.new(client).publish(
        NotionPublish::Document.load(path), target: target, manifest: map,
                                            properties: NotionPublish::PropertySet.build(
                                              front_matter: NotionPublish::Document.load(path).properties,
                                              pairs: properties
                                            ),
                                            title: title, title_given: !title.nil?, keep_h1: keep_h1
      )
      WebMock.reset_executed_requests!
      yield dir, path, map
    end
  end

  # Rewrites an entry the way an earlier version wrote it: no flag fields,
  # and one digest over every property.
  def downgrade(map, path)
    entry = map.entry(path)
    full = entry.flag_properties_sha256 ? "unknowable" : entry.properties_sha256
    raw = entry.to_h.except("flag_properties", "flag_properties_sha256").merge("properties_sha256" => full)
    map.pages[map.key_for(path)] = raw
    map.save
  end

  def target
    NotionPublish::Target.new(kind: :data_source, id: DS, title: "Docs", database_id: nil, inline: nil)
  end

  def stub_schema
    stub_notion(:get, "/v1/data_sources/#{DS}", status: 200, body: {
                  "object" => "data_source", "id" => DS, "title" => rich("Docs"),
                  "properties" => {
                    "Company Information" => { "id" => "title", "type" => "title", "title" => {} },
                    "Function" => { "id" => "f", "type" => "multi_select",
                                    "multi_select" => { "options" => [{ "name" => "Legal" }] } },
                    "Status" => { "id" => "s", "type" => "select",
                                  "select" => { "options" => [{ "name" => "Active" }, { "name" => "Draft" }] } }
                  }
                })
  end
end
