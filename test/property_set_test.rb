# frozen_string_literal: true

require "test_helper"

class PropertySetTest < Minitest::Test
  def test_a_pair_splits_on_the_first_equals
    assert_equal ["URL", "https://example.com/?a=b"],
                 NotionPublish::PropertySet.parse_pair("URL=https://example.com/?a=b")
  end

  def test_names_may_contain_spaces_and_punctuation
    assert_equal ["Company Information", "Q3 & Q4"],
                 NotionPublish::PropertySet.parse_pair("Company Information=Q3 & Q4")
  end

  def test_a_pair_without_an_equals_is_rejected
    error = assert_raises(NotionPublish::Error) { NotionPublish::PropertySet.parse_pair("Function") }

    assert_includes error.message, "--property 'Name=Value'"
  end

  def test_a_pair_with_an_empty_name_is_rejected
    assert_raises(NotionPublish::Error) { NotionPublish::PropertySet.parse_pair("=Operations") }
  end

  # Repeating the flag is how a multi-valued property gets more than one value.
  # Splitting on commas instead would break on an option that contains one.
  def test_repeating_a_name_accumulates
    set = NotionPublish::PropertySet.build(pairs: ["Function=Operations", "Function=Legal"])

    assert_equal %w[Operations Legal], set["Function"]
  end

  def test_different_names_stay_separate
    set = NotionPublish::PropertySet.build(pairs: ["Function=Operations", "Status=Active"])

    assert_equal ["Operations"], set["Function"]
    assert_equal ["Active"], set["Status"]
  end

  def test_front_matter_lists_become_multiple_values
    set = NotionPublish::PropertySet.build(front_matter: { "Function" => %w[Operations Legal] })

    assert_equal %w[Operations Legal], set["Function"]
  end

  def test_front_matter_scalars_are_stringified
    set = NotionPublish::PropertySet.build(front_matter: { "Done" => true, "Count" => 3 })

    assert_equal ["true"], set["Done"]
    assert_equal ["3"], set["Count"]
  end

  # A flag replaces the front matter for that name outright, so overriding one
  # value never drags the old ones along.
  def test_a_flag_replaces_front_matter_for_that_name
    set = NotionPublish::PropertySet.build(
      front_matter: { "Function" => %w[Operations Legal] },
      pairs: ["Function=Marketing"]
    )

    assert_equal ["Marketing"], set["Function"]
  end

  def test_other_names_survive_an_override
    set = NotionPublish::PropertySet.build(
      front_matter: { "Function" => ["Operations"], "Status" => ["Draft"] },
      pairs: ["Function=Marketing"]
    )

    assert_equal ["Draft"], set["Status"]
  end

  def test_json_layers_over_front_matter_and_under_flags
    set = NotionPublish::PropertySet.build(
      front_matter: { "Function" => ["Operations"], "Status" => ["Draft"] },
      json: '{"Function": ["Legal"], "Owner": "Someone"}',
      pairs: ["Status=Active"]
    )

    assert_equal ["Legal"], set["Function"]
    assert_equal ["Someone"], set["Owner"]
    assert_equal ["Active"], set["Status"]
  end

  def test_json_must_be_an_object
    error = assert_raises(NotionPublish::Error) { NotionPublish::PropertySet.build(json: "[1,2]") }

    assert_includes error.message, "must be a JSON object"
  end

  def test_malformed_json_is_reported
    error = assert_raises(NotionPublish::Error) { NotionPublish::PropertySet.build(json: "{oops") }

    assert_includes error.message, "Could not parse --properties-json"
  end

  def test_an_empty_value_is_kept_so_it_can_clear_a_property
    set = NotionPublish::PropertySet.build(pairs: ["Function="])

    assert_equal [""], set["Function"]
  end
end
