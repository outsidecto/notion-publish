# frozen_string_literal: true

require "test_helper"

# The five outcomes a publish can have, and the state that distinguishes them.
class PublishStateTest < Minitest::Test
  PAGE = "3cfab123-cd45-81fb-9c4d-f11bd6f8272a"
  DS = "2efab123-cd45-8088-a1d3-000b41c7f38c"
  BODY = "# Title\n\nSome body text.\n"

  def setup
    stub_me
    stub_schema
    @created = stub_request(:post, "#{StubbingHelpers::API}/v1/pages")
               .to_return(status: 200, body: JSON.generate("object" => "page", "id" => PAGE, "url" => "https://n/p/x"))
    @replaced = stub_request(:patch, "#{StubbingHelpers::API}/v1/pages/#{PAGE}/markdown")
                .to_return(status: 200, body: JSON.generate("object" => "page_markdown"))
    @patched = stub_request(:patch, "#{StubbingHelpers::API}/v1/pages/#{PAGE}")
               .to_return(status: 200, body: JSON.generate("object" => "page", "id" => PAGE, "url" => "https://n/p/x"))
    stub_request(:get, "#{StubbingHelpers::API}/v1/pages/#{PAGE}")
      .to_return(status: 200, body: JSON.generate("object" => "page", "id" => PAGE, "url" => "https://n/p/x"))
    stub_markdown("Some body text.")
  end

  def test_a_first_publish_creates_and_records_everything
    with_doc do |path, map|
      outcome = publish(path, map)

      assert_equal :created, outcome.action
      entry = map.entry(path)

      assert_equal PAGE, entry.id
      assert_equal Digest::SHA256.hexdigest(File.binread(path)), entry.source_sha256
      assert_equal Digest::SHA256.hexdigest("Some body text."), entry.notion_sha256
      assert_equal DS, entry.parent["id"]
      assert_includes entry.properties, "Company Information"
    end
  end

  def test_an_unchanged_source_sends_nothing
    with_doc do |path, map|
      publish(path, map)
      WebMock.reset_executed_requests!

      assert_equal :unchanged, publish(path, map).action
      assert_not_requested @created
      assert_not_requested @replaced
    end
  end

  def test_a_changed_source_updates_in_place_and_keeps_the_url
    with_doc do |path, map|
      publish(path, map)
      File.write(path, "# Title\n\nRewritten.\n")

      outcome = publish(path, map)

      assert_equal :updated, outcome.action
      assert_equal "https://n/p/x", outcome.url
      assert_requested @replaced
      assert_requested(:patch, "#{StubbingHelpers::API}/v1/pages/#{PAGE}/markdown") do |req|
        JSON.parse(req.body)["type"] == "replace_content"
      end
    end
  end

  # Notion's own output is hashed on both sides, because a round trip is not
  # byte-stable and the sent form would never match a later read.
  def test_a_page_edited_in_notion_blocks_the_publish
    with_doc do |path, map|
      publish(path, map)
      File.write(path, "# Title\n\nRewritten.\n")
      stub_markdown("Somebody edited this in Notion.")

      outcome = publish(path, map)

      assert_equal :blocked, outcome.action
      assert_includes outcome.detail, "changed in Notion"
      assert_includes outcome.detail, "--force"
    end
  end

  def test_force_overrides_drift
    with_doc do |path, map|
      publish(path, map)
      File.write(path, "# Title\n\nRewritten.\n")
      stub_markdown("Somebody edited this in Notion.")

      assert_equal :updated, publish(path, map, force: true).action
    end
  end

  # Declarative, but only over properties this tool set last time.
  def test_a_property_dropped_from_the_source_is_cleared
    with_doc do |path, map|
      publish(path, map, properties: ["Function=Legal", "Owner=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"])

      assert_equal ["Company Information", "Function", "Owner"], map.entry(path).properties.sort

      File.write(path, "# Title\n\nRewritten.\n")
      publish(path, map, properties: ["Function=Legal"])

      assert_requested(:patch, "#{StubbingHelpers::API}/v1/pages/#{PAGE}") do |req|
        props = JSON.parse(req.body)["properties"]
        props.dig("Function", "multi_select") == [{ "name" => "Legal" }] &&
          props.dig("Owner", "people") == []
      end
      refute_includes map.entry(path).properties, "Owner"
    end
  end

  def test_a_property_the_tool_never_set_is_left_alone
    with_doc do |path, map|
      publish(path, map, properties: ["Function=Legal"])
      File.write(path, "# Title\n\nRewritten.\n")
      publish(path, map, properties: ["Function=Legal"])

      assert_requested(:patch, "#{StubbingHelpers::API}/v1/pages/#{PAGE}") do |req|
        !JSON.parse(req.body)["properties"].key?("Status")
      end
    end
  end

  # A stale entry is not fatal: forget it and publish afresh.
  def test_an_entry_pointing_at_a_deleted_page_recovers
    with_doc do |path, map|
      publish(path, map)
      File.write(path, "# Title\n\nRewritten.\n")
      stub_request(:get, "#{StubbingHelpers::API}/v1/pages/#{PAGE}")
        .to_return(status: 404, body: JSON.generate("object" => "error", "status" => 404,
                                                    "code" => "object_not_found", "message" => "gone"))
      warnings = []

      outcome = publish(path, map, warnings: warnings)

      assert_equal :created, outcome.action
      assert_includes warnings.join, "gone from Notion"
    end
  end

  def test_replacing_a_page_with_child_pages_is_refused_clearly
    with_doc do |path, map|
      publish(path, map)
      File.write(path, "# Title\n\nRewritten.\n")
      stub_request(:patch, "#{StubbingHelpers::API}/v1/pages/#{PAGE}/markdown")
        .to_return(status: 400, body: JSON.generate("object" => "error", "status" => 400,
                                                    "code" => "validation_error",
                                                    "message" => "would delete child pages"))

      error = assert_raises(NotionPublish::Error) { publish(path, map) }
      assert_includes error.message, "child page"
      assert_includes error.message, "will not do that silently"
    end
  end

  # Reworking only the properties is a change worth publishing, and it should
  # not mean rewriting every block on the page.
  def test_changed_properties_alone_trigger_a_properties_only_update
    with_doc do |path, map|
      publish(path, map, properties: ["Function=Legal"])
      WebMock.reset_executed_requests!

      outcome = publish(path, map, properties: ["Function=Legal", "Owner=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"])

      assert_equal :properties, outcome.action
      assert_requested @patched
      assert_not_requested @replaced
    end
  end

  def test_the_same_properties_are_still_unchanged
    with_doc do |path, map|
      publish(path, map, properties: ["Function=Legal"])

      assert_equal :unchanged, publish(path, map, properties: ["Function=Legal"]).action
    end
  end

  def test_force_properties_reapplies_them_with_nothing_changed
    with_doc do |path, map|
      publish(path, map, properties: ["Function=Legal"])
      WebMock.reset_executed_requests!

      outcome = publish(path, map, properties: ["Function=Legal"], force_properties: true)

      assert_equal :properties, outcome.action
      assert_requested @patched
      assert_not_requested @replaced
    end
  end

  # An entry from an older version, or from `adopt`, has no property digest. It
  # must not be read as "the properties already match".
  def test_an_entry_without_a_property_digest_applies_them_once
    with_doc do |path, map|
      publish(path, map, properties: ["Function=Legal"])
      entry = map.entry(path)
      map.record(path, NotionPublish::PageMap::Entry.new(
                         id: entry.id, url: entry.url, parent: entry.parent,
                         properties: entry.properties, source_sha256: entry.source_sha256,
                         notion_sha256: entry.notion_sha256
                       ))
      WebMock.reset_executed_requests!

      assert_equal :properties, publish(path, map, properties: ["Function=Legal"]).action
      refute_nil map.entry(path).properties_sha256, "and records the digest, so the next run is quiet"
    end
  end

  # A body change carries the properties with it; no second decision needed.
  def test_a_body_change_updates_both
    with_doc do |path, map|
      publish(path, map, properties: ["Function=Legal"])
      File.write(path, "# Title\n\nRewritten.\n")

      assert_equal :updated, publish(path, map, properties: ["Function=Legal"]).action
      assert_requested @replaced
    end
  end

  def test_flag_set_properties_and_overrides_are_recorded
    with_doc do |path, map|
      NotionPublish::Publisher.new(client).publish(
        NotionPublish::Document.load(path), target: target, map: map,
                                            properties: NotionPublish::PropertySet.build(pairs: ["Function=Legal"]),
                                            title: "Chosen", title_given: true, keep_h1: true
      )
      entry = map.entry(path)

      assert_equal ["Function"], entry.flag_properties
      assert_equal "Chosen", entry.title_override
      assert entry.keep_h1
      refute_nil entry.flag_properties_sha256
      assert_equal ["Company Information", "Function"], entry.properties
    end
  end

  def test_a_publish_without_flags_records_an_empty_list
    with_doc do |path, map|
      publish(path, map)
      entry = map.entry(path)

      assert_equal [], entry.flag_properties
      assert_nil entry.title_override
      assert_nil entry.keep_h1
      assert_nil entry.flag_properties_sha256
      refute_includes File.read(map.path), "title_override"
    end
  end

  def test_changing_a_flag_value_is_still_a_change
    with_doc do |path, map|
      publish(path, map, properties: ["Function=Legal"])

      assert_equal :unchanged, publish(path, map, properties: ["Function=Legal"]).action
      assert_equal :properties, publish(path, map, properties: ["Function="]).action
    end
  end

  # Entries written before the digest was split hash every property together.
  # Without flags, that is the same hash, so they stay unchanged.
  def test_an_older_entry_without_flags_is_still_unchanged
    with_doc do |path, map|
      publish(path, map)
      raw = map.entry(path).to_h.except("flag_properties")
      map.pages[map.key_for(path)] = raw
      map.save
      WebMock.reset_executed_requests!

      assert_equal :unchanged, publish(path, map).action
    end
  end

  private

  def target
    NotionPublish::Target.new(kind: :data_source, id: DS, title: "Docs", database_id: "db1", inline: nil)
  end

  def publish(path, map, properties: [], force: false, force_properties: false, warnings: [])
    NotionPublish::Publisher.new(client).publish(
      NotionPublish::Document.load(path), target: target, map: map,
                                          properties: NotionPublish::PropertySet.build(pairs: properties),
                                          warnings: warnings, force: force, force_properties: force_properties
    )
  end

  def stub_markdown(text)
    stub_request(:get, "#{StubbingHelpers::API}/v1/pages/#{PAGE}/markdown")
      .to_return(status: 200, body: JSON.generate("object" => "page_markdown", "markdown" => text))
  end

  def stub_schema
    stub_notion(:get, "/v1/data_sources/#{DS}", status: 200, body: {
                  "object" => "data_source", "id" => DS, "title" => rich("Docs"),
                  "properties" => {
                    "Company Information" => { "id" => "title", "type" => "title", "title" => {} },
                    "Function" => { "id" => "f", "type" => "multi_select",
                                    "multi_select" => { "options" => [{ "name" => "Legal" }] } },
                    "Owner" => { "id" => "o", "type" => "people", "people" => {} },
                    "Status" => { "id" => "s", "type" => "select",
                                  "select" => { "options" => [{ "name" => "Active" }] } }
                  }
                })
  end

  def with_doc
    Dir.mktmpdir do |dir|
      path = File.join(dir, "doc.md")
      File.write(path, BODY)
      yield path, NotionPublish::PageMap.new(File.join(dir, NotionPublish::PageMap::FILENAME))
    end
  end
end
