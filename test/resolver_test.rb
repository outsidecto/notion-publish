# frozen_string_literal: true

require "test_helper"

class ResolverTest < Minitest::Test
  UUID = "32dab123-cd45-803f-94c2-d29516bd0188"
  DS = "2efab123-cd45-8088-a1d3-000b41c7f38c"

  def setup
    stub_me(name: "Security and Compliance Publishing")
    @resolver = NotionPublish::Resolver.new(client)
  end

  def test_resolves_a_page_in_one_call
    stub_block(UUID, "child_page", { "title" => "Security and Compliance (S&C)" })

    target = @resolver.resolve(UUID)

    assert_predicate target, :page?
    assert_equal({ "page_id" => UUID }, target.parent_param)
    assert_equal "Security and Compliance (S&C)", target.title
    assert_not_requested :get, "#{StubbingHelpers::API}/v1/databases/#{UUID}"
    assert_not_requested :get, "#{StubbingHelpers::API}/v1/data_sources/#{UUID}"
  end

  # A database row is a child_page too, with its parent pointing at the data
  # source, so rows work as parents like any other page.
  def test_database_row_resolves_as_a_page
    stub_block(UUID, "child_page", { "title" => "Puente Retro 8/31" })

    assert_predicate @resolver.resolve(UUID), :page?
  end

  # A database with one data source resolves to that source: the schema and the
  # rows live there, and a bare database parent breaks once a second is added.
  def test_database_resolves_to_its_only_data_source
    stub_block(UUID, "child_database", { "title" => "Policies" })
    stub_notion(:get, "/v1/databases/#{UUID}", status: 200, body: {
                  "object" => "database", "id" => UUID, "title" => rich("Policies"),
                  "is_inline" => false,
                  "data_sources" => [{ "id" => DS, "name" => "Policies" }]
                })

    target = @resolver.resolve(UUID)

    assert_equal DS, target.id
    assert_equal UUID, target.database_id
  end

  def test_database_with_two_data_sources_is_ambiguous
    stub_block(UUID, "child_database", { "title" => "Docs" })
    stub_notion(:get, "/v1/databases/#{UUID}", status: 200, body: {
                  "object" => "database", "id" => UUID, "title" => rich("Docs"), "is_inline" => false,
                  "data_sources" => [{ "id" => "ds-1", "name" => "Current" }, { "id" => "ds-2", "name" => "Archive" }]
                })

    error = assert_raises(NotionPublish::Resolver::Ambiguous) { @resolver.resolve(UUID) }

    assert_includes error.message, "2 data sources"
    assert_includes error.message, "--parent ds-2"
  end

  # is_inline lives on the database object and nowhere else.
  def test_inline_comes_from_the_database_object
    stub_block(UUID, "child_database", { "title" => "Notes" })
    stub_notion(:get, "/v1/databases/#{UUID}", status: 200, body: {
                  "object" => "database", "id" => UUID, "title" => rich("Notes"), "is_inline" => true,
                  "data_sources" => [{ "id" => DS, "name" => "Notes" }]
                })

    assert_equal "inline database", @resolver.resolve(UUID).kind_label
  end

  # A data source is not a block, so /v1/blocks 404s and the typed call decides.
  def test_data_source_falls_through_the_block_lookup
    stub_missing(:get, "/v1/blocks/#{DS}", DS)
    stub_notion(:get, "/v1/data_sources/#{DS}", status: 200, body: {
                  "object" => "data_source", "id" => DS, "title" => rich("Policies"),
                  "parent" => { "type" => "database_id", "database_id" => UUID }
                })

    target = @resolver.resolve(DS)

    assert_predicate target, :data_source?
    assert_nil target.inline, "a data source does not carry is_inline"
  end

  def test_a_plain_block_id_is_rejected_by_kind
    stub_block(UUID, "paragraph", { "rich_text" => [] })

    error = assert_raises(NotionPublish::Resolver::WrongKind) { @resolver.resolve(UUID) }

    assert_includes error.message, "paragraph block"
  end

  # Notion answers 404 both for objects that do not exist and for objects that
  # are not shared, so the message has to name the connection and admit it
  # cannot tell the two apart.
  def test_unreachable_names_the_connection_and_the_slug_title
    stub_missing(:get, "/v1/blocks/#{UUID}", UUID)
    stub_missing(:get, "/v1/data_sources/#{UUID}", UUID)

    error = assert_raises(NotionPublish::Resolver::Unreachable) do
      @resolver.resolve("https://app.notion.com/p/Security-and-Compliance-S-C-#{UUID.delete('-')}")
    end

    assert_includes error.message, "Security and Compliance S C"
    assert_includes error.message, "Security and Compliance Publishing"
    assert_includes error.message, "does not exist"
  end

  def test_non_404_api_errors_are_not_swallowed
    stub_notion(:get, "/v1/blocks/#{UUID}", status: 403, body: {
                  "object" => "error", "status" => 403, "code" => "restricted_resource", "message" => "no"
                })

    error = assert_raises(NotionPublish::ApiError) { @resolver.resolve(UUID) }
    assert_predicate error, :restricted?
  end

  # --parent takes an ID, a URL, or a name, and works out which.
  def test_parent_dispatches_a_url_to_id_lookup
    stub_block(UUID, "child_page", { "title" => "Page" })

    assert_predicate @resolver.resolve("https://app.notion.com/p/Some-Page-#{UUID.delete('-')}?v=#{'a' * 32}&pvs=9"),
                     :page?
  end

  def test_parent_dispatches_a_name_to_search
    stub_search([{ "id" => DS, "title" => rich("Policies") }])

    assert_equal DS, @resolver.resolve("Policies").id
  end

  # Anchored ID matching: a name with an ID inside it is still a name.
  def test_a_name_containing_an_id_is_treated_as_a_name
    stub_search([])

    assert_raises(NotionPublish::Resolver::NotNamed) { @resolver.resolve("Q3 Report #{UUID.delete('-')}") }
  end

  def test_database_name_exact_match
    stub_search([{ "id" => DS, "title" => rich("Company Milestones") }])

    target = @resolver.resolve_database_name("company milestones")

    assert_equal DS, target.id
  end

  # Notion's search is fuzzy and relevance-ranked, so one hit is not one match.
  # Near misses are listed, never published into.
  def test_fuzzy_only_match_is_refused_and_candidates_listed
    stub_search([
                  { "id" => "ds-1", "title" => rich("Acme Team Members") },
                  { "id" => "ds-2", "title" => rich("Acme — Launch Calendar") }
                ])

    error = assert_raises(NotionPublish::Resolver::NotNamed) { @resolver.resolve_database_name("Acme") }

    assert_includes error.message, "No database is named \"Acme\""
    assert_includes error.message, "Acme Team Members"
    assert_includes error.message, "--parent ds-2"
  end

  def test_no_candidates_points_at_sharing
    stub_search([])

    error = assert_raises(NotionPublish::Resolver::NotNamed) { @resolver.resolve_database_name("Nope") }

    assert_includes error.message, "Security and Compliance Publishing"
    assert_includes error.message, "Connections"
  end

  def test_duplicate_exact_names_are_ambiguous
    stub_search([
                  { "id" => "ds-1", "title" => rich("Notes") },
                  { "id" => "ds-2", "title" => rich("Notes") }
                ])

    error = assert_raises(NotionPublish::Resolver::Ambiguous) { @resolver.resolve_database_name("Notes") }

    assert_includes error.message, "More than one database"
    assert_includes error.message, "--parent ds-1"
  end

  # One data source in this workspace has an empty title, so --database can
  # never reach it. It should still be listed as a candidate with its ID.
  def test_untitled_data_source_is_listed_as_a_candidate
    stub_search([{ "id" => "ds-blank", "title" => [] }])

    error = assert_raises(NotionPublish::Resolver::NotNamed) { @resolver.resolve_database_name("Something") }

    assert_includes error.message, "(untitled)"
    assert_includes error.message, "ds-blank"
  end

  def test_an_exact_name_on_a_later_page_of_search_results_is_found
    search = "#{StubbingHelpers::API}/v1/search"
    stub_request(:post, search).with(body: hash_excluding("start_cursor" => "c2"))
                               .to_return(status: 200, body: JSON.generate(
                                 "results" => [{ "id" => "ds-1", "title" => rich("Policies (archive)") }],
                                 "has_more" => true, "next_cursor" => "c2"
                               ))
    stub_request(:post, search).with(body: hash_including("start_cursor" => "c2"))
                               .to_return(status: 200, body: JSON.generate(
                                 "results" => [{ "id" => DS, "title" => rich("Policies") }], "has_more" => false
                               ))

    assert_equal DS, @resolver.resolve_database_name("Policies").id
  end

  private

  def stub_search(results)
    stub_request(:post, "#{StubbingHelpers::API}/v1/search")
      .with(body: hash_including("filter" => { "property" => "object", "value" => "data_source" }))
      .to_return(status: 200, body: JSON.generate("object" => "list", "results" => results))
  end
end
