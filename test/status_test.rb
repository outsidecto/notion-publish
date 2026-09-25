# frozen_string_literal: true

require "test_helper"

# status answers "what would happen if I published everything", and exits 3 when
# a tracked document needs something doing to it.
class StatusTest < Minitest::Test
  BODY = "# Title\n\nBody.\n"

  def test_everything_in_sync_exits_zero
    with_tree("a.md" => :synced) do |dir|
      code, out, = run_cli(["status", dir])

      assert_equal NotionPublish::CLI::OK, code
      assert_includes out, "Everything is in sync."
      assert_includes out, "1 tracked"
    end
  end

  def test_a_locally_changed_file_is_reported_and_exits_three
    with_tree("a.md" => :modified) do |dir|
      code, out, = run_cli(["status", dir])

      assert_equal NotionPublish::CLI::BLOCKED, code
      assert_includes out, "changed locally"
      assert_includes out, "a.md"
    end
  end

  def test_a_page_edited_in_notion_is_reported
    with_tree("a.md" => :drifted) do |dir|
      code, out, = run_cli(["status", dir])

      assert_equal NotionPublish::CLI::BLOCKED, code
      assert_includes out, "changed in Notion"
    end
  end

  def test_both_sides_changed_is_its_own_state
    with_tree("a.md" => :diverged) do |dir|
      _, out, = run_cli(["status", dir])

      assert_includes out, "changed in both"
    end
  end

  def test_a_deleted_page_is_reported
    with_tree("a.md" => :missing) do |dir|
      _, out, = run_cli(["status", dir])

      assert_includes out, "page is gone from Notion"
    end
  end

  def test_an_entry_without_a_source_file_is_orphaned
    with_tree("a.md" => :orphaned) do |dir|
      code, out, = run_cli(["status", dir])

      assert_equal NotionPublish::CLI::BLOCKED, code
      assert_includes out, "no source file"
    end
  end

  # Plenty of Markdown is deliberately not mirrored, so an unpublished file is
  # information rather than a problem.
  def test_unpublished_files_are_counted_but_do_not_fail_the_check
    with_tree("a.md" => :synced) do |dir|
      File.write(File.join(dir, "notes.md"), "not for Notion\n")

      code, out, = run_cli(["status", dir])

      assert_equal NotionPublish::CLI::OK, code
      assert_includes out, "Never published (1): pass --untracked to list them"
      refute_includes out, "notes.md"
    end
  end

  def test_untracked_lists_unpublished_files
    with_tree("a.md" => :synced) do |dir|
      File.write(File.join(dir, "notes.md"), "not for Notion\n")

      _, out, = run_cli(["status", dir, "--untracked"])

      assert_includes out, "Never published (1)\n  notes.md"
    end
  end

  # What is published matters as much as what is not.
  def test_documents_in_sync_are_listed
    with_tree("a.md" => :synced, "b.md" => :modified) do |dir|
      _, out, = run_cli(["status", dir])

      assert_includes out, "In sync (1)\n  a.md"
      assert_operator out.index("Changed locally (1)"), :<, out.index("In sync (1)"), "problems come first"
    end
  end

  def test_local_skips_the_notion_check_entirely
    with_tree("a.md" => :drifted) do |dir|
      WebMock.reset_executed_requests!

      code, out, = run_cli(["status", dir, "--local"])

      assert_equal NotionPublish::CLI::OK, code, "without asking Notion, only the source hash is known"
      assert_includes out, "--local was given"
      assert_not_requested :get, %r{/v1/pages/.*/markdown}
    end
  end

  def test_json_emits_one_object_per_document
    with_tree("a.md" => :modified) do |dir|
      code, out, = run_cli(["status", dir, "--json"])

      assert_equal NotionPublish::CLI::BLOCKED, code
      row = JSON.parse(out.lines.first)

      assert_equal "a.md", row["source"]
      assert_equal "modified", row["state"]
    end
  end

  def test_a_directory_with_no_map_says_so
    Dir.mktmpdir do |dir|
      code, _, err = run_cli(["status", dir])

      assert_equal NotionPublish::CLI::FAILURE, code
      assert_includes err, "Nothing published yet"
    end
  end

  private

  def with_tree(files)
    Dir.mktmpdir do |dir|
      stub_me
      map = NotionPublish::PageMap.new(File.join(dir, NotionPublish::PageMap::FILENAME))

      files.each_with_index do |(name, kind), i|
        id = "page-#{i}"
        path = File.join(dir, name)
        File.write(path, BODY) unless kind == :orphaned
        source_hash = kind == :orphaned ? "x" : Digest::SHA256.hexdigest(BODY)
        source_hash = "stale" if %i[modified diverged].include?(kind)

        map.record(path, NotionPublish::PageMap::Entry.new(
                           id: id, url: "https://n/p/#{id}", parent: nil, properties: [],
                           source_sha256: source_hash, notion_sha256: Digest::SHA256.hexdigest("published"),
                           published_at: nil
                         ))
        stub_page_markdown(id, kind)
      end
      yield dir
    end
  end

  def stub_page_markdown(id, kind)
    url = "#{StubbingHelpers::API}/v1/pages/#{id}/markdown"
    case kind
    when :missing
      stub_request(:get, url).to_return(status: 404, body: JSON.generate(
        "object" => "error", "status" => 404, "code" => "object_not_found", "message" => "gone"
      ))
    when :drifted, :diverged
      stub_request(:get, url).to_return(status: 200, body: JSON.generate("markdown" => "somebody edited this"))
    else
      stub_request(:get, url).to_return(status: 200, body: JSON.generate("markdown" => "published"))
    end
  end
end
