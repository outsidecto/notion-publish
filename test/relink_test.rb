# frozen_string_literal: true

require "test_helper"

# Links to documents published later get repaired afterwards. Notion rewrites a
# relative target to https://<target>, so that mangled form is what must match.
class RelinkTest < Minitest::Test
  IDS = { "a" => "page-a", "b" => "page-b" }.freeze

  def test_a_mangled_link_is_replaced_with_the_published_url
    with_published do |dir|
      stub_markdown("a", "See [B](https://b.md) for details.\n")
      stub_markdown("b", "Nothing to fix.\n")
      stub_patch("a")

      code, out, = run_cli(["relink", dir])

      assert_equal NotionPublish::CLI::OK, code
      assert_includes out, "a.md: fixed 1 link"
      refute_includes out, "Fixed 1 links."
      assert_requested(:patch, "#{StubbingHelpers::API}/v1/pages/#{IDS['a']}/markdown") do |req|
        u = JSON.parse(req.body).dig("update_content", "content_updates", 0)
        u["old_str"] == "](https://b.md)" && u["new_str"] == "](https://notion.so/B)" &&
          u["replace_all_matches"] == true
      end
    end
  end

  def test_pages_with_nothing_to_fix_are_not_patched
    with_published do |dir|
      stub_markdown("a", "No links here.\n")
      stub_markdown("b", "None either.\n")
      patch = stub_patch("a")

      _, out, = run_cli(["relink", dir])

      assert_includes out, "No links needed fixing."
      assert_not_requested patch
    end
  end

  # The tool cannot tell a retirement from a rename, so it reports and stops.
  def test_entries_without_a_source_file_are_reported
    with_published(write_sources: false) do |dir|
      stub_markdown("a", "x\n")
      stub_markdown("b", "y\n")

      _, _, err = run_cli(["relink", dir])

      assert_includes err, "2 entries have no source file"
      assert_includes err, "still live"
    end
  end

  def test_an_unpublished_directory_is_reported
    Dir.mktmpdir do |dir|
      code, _, err = run_cli(["relink", dir])

      assert_equal NotionPublish::CLI::FAILURE, code
      assert_includes err, "Nothing published yet"
    end
  end

  private

  def with_published(write_sources: true)
    Dir.mktmpdir do |dir|
      stub_me
      map = NotionPublish::PageMap.new(File.join(dir, NotionPublish::PageMap::FILENAME))
      %w[a b].each do |name|
        File.write(File.join(dir, "#{name}.md"), "x") if write_sources
        entry = NotionPublish::PageMap::Entry.new(id: IDS[name], url: "https://notion.so/#{name.upcase}")
        map.record(File.join(dir, "#{name}.md"), entry)
      end
      yield dir
    end
  end

  def stub_markdown(name, markdown)
    stub_request(:get, "#{StubbingHelpers::API}/v1/pages/#{IDS[name]}/markdown")
      .to_return(status: 200, body: JSON.generate("object" => "page_markdown", "markdown" => markdown))
  end

  def stub_patch(name)
    stub_request(:patch, "#{StubbingHelpers::API}/v1/pages/#{IDS[name]}/markdown")
      .to_return(status: 200, body: JSON.generate("object" => "page_markdown", "markdown" => ""))
  end
end
