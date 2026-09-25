# frozen_string_literal: true

require "test_helper"

# Settings are hand-written and merged from the repository root down to the
# document, closest winning, the way .rubocop.yml and .editorconfig behave.
class SettingsTest < Minitest::Test
  def test_no_files_is_empty
    Dir.mktmpdir { |dir| assert_empty NotionPublish::Settings.for(dir) }
  end

  def test_a_single_file_is_read
    with_tree("" => "database: References\nicon: \"🔒\"\n") do |root|
      settings = NotionPublish::Settings.for(root)

      assert_equal "References", settings.database
      assert_equal "🔒", settings.icon
    end
  end

  def test_a_nearer_file_wins_per_key
    with_tree("" => "database: Root\nicon: \"🔒\"\n", "policies" => "database: References\n") do |root|
      settings = NotionPublish::Settings.for(File.join(root, "policies"))

      assert_equal "References", settings.database, "the nearer file wins"
      assert_equal "🔒", settings.icon, "keys it does not set are inherited"
    end
  end

  def test_merging_stops_at_the_repository_root
    with_tree("" => "database: Outside\n", "repo" => "database: Inside\n", "repo/docs" => nil) do |root|
      Dir.mkdir(File.join(root, "repo", ".git"))

      settings = NotionPublish::Settings.for(File.join(root, "repo", "docs"))

      assert_equal "Inside", settings.database
      assert_equal [File.join(root, "repo", ".notion-publish.yml")], settings.files
    end
  end

  # A typo in a settings key should be reported, not silently ignored.
  def test_an_unknown_key_is_refused
    with_tree("" => "databse: References\n") do |root|
      error = assert_raises(NotionPublish::ConfigError) { NotionPublish::Settings.for(root) }

      assert_includes error.message, "unknown setting"
      assert_includes error.message, "databse"
    end
  end

  # Records of published pages belong in the manifest, never in settings.
  def test_state_keys_in_settings_are_refused
    with_tree("" => "database: References\npages:\n  a.md:\n    id: x\n") do |root|
      error = assert_raises(NotionPublish::ConfigError) { NotionPublish::Settings.for(root) }

      assert_includes error.message, "unknown setting \"pages\""
    end
  end

  def test_a_malformed_file_names_itself
    with_tree("" => "database: [unclosed\n") do |root|
      error = assert_raises(NotionPublish::ConfigError) { NotionPublish::Settings.for(root) }

      assert_includes error.message, ".notion-publish.yml"
    end
  end

  private

  def with_tree(files)
    Dir.mktmpdir do |root|
      files.each do |sub, content|
        dir = sub.empty? ? root : File.join(root, sub)
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, ".notion-publish.yml"), content) if content
      end
      yield root
    end
  end
end
