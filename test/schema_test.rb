# frozen_string_literal: true

require "test_helper"

# The fixture mirrors the shape of the Policies data source,
# including its duplicated Function / Function 1 pair.
class SchemaTest < Minitest::Test
  PROPERTIES = {
    "Company Information" => { "id" => "title", "type" => "title", "title" => {} },
    "Function" => { "id" => "%40KQF", "type" => "multi_select", "multi_select" => {
      "options" => [{ "name" => "Operations" }, { "name" => "Security and Compliance" },
                    { "name" => "finance" }, { "name" => "Legal" }]
    } },
    "Function 1" => { "id" => "926f", "type" => "select", "select" => {
      "options" => [{ "name" => "Operations" }, { "name" => "Finance" }]
    } },
    "Status 1" => { "id" => "5c94", "type" => "status", "status" => {
      "options" => [{ "name" => "Not started" }, { "name" => "Done" }]
    } },
    "Author" => { "id" => "%40gjX", "type" => "people", "people" => {} },
    "Due Date" => { "id" => "7956", "type" => "date", "date" => {} },
    "Notes" => { "id" => "nnnn", "type" => "rich_text", "rich_text" => {} },
    "Done" => { "id" => "dddd", "type" => "checkbox", "checkbox" => {} },
    "Score" => { "id" => "ssss", "type" => "number", "number" => {} },
    "Site" => { "id" => "uuuu", "type" => "url", "url" => {} },
    "Related" => { "id" => "rrrr", "type" => "relation", "relation" => {} },
    "Last edited by" => { "id" => "e%5Col", "type" => "last_edited_by", "last_edited_by" => {} },
    "Last updated" => { "id" => "Y%5D", "type" => "last_edited_time", "last_edited_time" => {} }
  }.freeze

  def schema = NotionPublish::Schema.new(PROPERTIES)

  def test_title_key_is_found_by_type_not_by_name
    assert_equal "Company Information", schema.title_key
  end

  def test_property_names_match_case_insensitively
    key, = schema.build("due date", ["2026-09-15"])

    assert_equal "Due Date", key
  end

  def test_multi_select_takes_several_values
    key, payload = schema.build("Function", ["Operations", "Security and Compliance"])

    assert_equal "Function", key
    assert_equal [{ "name" => "Operations" }, { "name" => "Security and Compliance" }],
                 payload["multi_select"]
  end

  # Option matching is case-insensitive but the stored value keeps Notion's
  # spelling, so "finance" does not become "Finance".
  def test_option_casing_is_canonicalised
    _, payload = schema.build("Function", ["FINANCE"])

    assert_equal [{ "name" => "finance" }], payload["multi_select"]
  end

  # Notion creates an unrecognised option instead of rejecting it, which would
  # silently grow the schema on a typo.
  def test_an_unknown_option_is_refused_with_the_real_options
    error = assert_raises(NotionPublish::Error) { schema.build("Function", ["Opperations"]) }

    assert_includes error.message, "no option named \"Opperations\""
    assert_includes error.message, "Security and Compliance"
    assert_includes error.message, "Notion would create a new option"
  end

  def test_a_single_valued_property_rejects_two_values
    error = assert_raises(NotionPublish::Error) { schema.build("Function 1", %w[Operations Finance]) }

    assert_includes error.message, "takes one value; you gave 2"
  end

  def test_computed_properties_cannot_be_set
    error = assert_raises(NotionPublish::Error) { schema.build("Last edited by", ["someone"]) }

    assert_includes error.message, "Notion computes it"
  end

  def test_unknown_property_suggests_near_names
    error = assert_raises(NotionPublish::Error) { schema.build("Funktion", ["Operations"]) }

    assert_includes error.message, "no property named \"Funktion\""
    assert_includes error.message, "Function"
  end

  def test_status_and_select_build_a_name_object
    _, status = schema.build("Status 1", ["Done"])
    _, select = schema.build("Function 1", ["Operations"])

    assert_equal({ "status" => { "name" => "Done" } }, status)
    assert_equal({ "select" => { "name" => "Operations" } }, select)
  end

  def test_dates_accept_a_range
    _, payload = schema.build("Due Date", ["2026-09-15..2026-09-20"])

    assert_equal({ "start" => "2026-09-15", "end" => "2026-09-20" }, payload["date"])
  end

  def test_dates_without_a_range_have_no_end
    _, payload = schema.build("Due Date", ["2026-09-15"])

    assert_equal({ "start" => "2026-09-15" }, payload["date"])
  end

  def test_checkbox_accepts_words_and_digits
    assert_equal({ "checkbox" => true }, schema.build("Done", ["yes"]).last)
    assert_equal({ "checkbox" => false }, schema.build("Done", ["0"]).last)
  end

  def test_checkbox_rejects_nonsense
    error = assert_raises(NotionPublish::Error) { schema.build("Done", ["maybe"]) }

    assert_includes error.message, "Use true or false"
  end

  def test_numbers_keep_integers_and_floats
    assert_equal({ "number" => 3 }, schema.build("Score", ["3"]).last)
    assert_equal({ "number" => 3.5 }, schema.build("Score", ["3.5"]).last)
  end

  def test_numbers_reject_text
    assert_raises(NotionPublish::Error) { schema.build("Score", ["high"]) }
  end

  def test_relations_accept_ids_and_urls
    _, payload = schema.build("Related", ["https://app.notion.com/p/Some-Page-#{'a' * 32}"])

    assert_equal [{ "id" => "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" }], payload["relation"]
  end

  def test_people_accept_a_bare_id_without_a_lookup
    _, payload = schema.build("Author", ["aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"])

    assert_equal [{ "object" => "user", "id" => "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" }], payload["people"]
  end

  def test_people_resolve_names_through_the_directory
    stub_request(:get, %r{/v1/users}).to_return(status: 200, body: JSON.generate(
      "results" => [{ "id" => "u-1", "name" => "Jane Doe", "type" => "person" }], "has_more" => false
    ))

    _, payload = schema.build("Author", ["jane doe"], users: NotionPublish::Users.new(client))

    assert_equal [{ "object" => "user", "id" => "u-1" }], payload["people"]
  end

  def test_an_unknown_person_is_reported_with_close_matches
    stub_request(:get, %r{/v1/users}).to_return(status: 200, body: JSON.generate(
      "results" => [{ "id" => "u-1", "name" => "Jane Doe", "type" => "person" }], "has_more" => false
    ))

    error = assert_raises(NotionPublish::Error) do
      schema.build("Author", ["Jane Dooe"], users: NotionPublish::Users.new(client))
    end

    assert_includes error.message, "No workspace user is named"
    assert_includes error.message, "Jane Doe"
  end

  def test_an_empty_value_clears_a_property
    assert_equal({ "multi_select" => [] }, schema.build("Function", [""]).last)
    assert_equal({ "date" => nil }, schema.build("Due Date", [""]).last)
    assert_equal({ "rich_text" => [] }, schema.build("Notes", [""]).last)
  end

  def test_url_properties_are_plain_strings
    assert_equal({ "url" => "https://example.com" }, schema.build("Site", ["https://example.com"]).last)
  end

  # A page parent has no schema: title is the only property Notion accepts.
  def test_a_page_parent_accepts_only_a_title
    page_schema = NotionPublish::Schema.new({}, page: true)

    key, payload = page_schema.build("title", ["Hello"])

    assert_equal "title", key
    assert_equal "Hello", payload.dig("title", 0, "text", "content")

    error = assert_raises(NotionPublish::Error) { page_schema.build("Function", ["Operations"]) }
    assert_includes error.message, "page parent accepts only a title"
  end
end
