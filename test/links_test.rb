# frozen_string_literal: true

require "test_helper"

class LinksTest < Minitest::Test
  def with_registry
    Dir.mktmpdir do |dir|
      map = NotionPublish::Manifest.new(File.join(dir, NotionPublish::Manifest::FILENAME))
      yield map, dir
    end
  end

  def record(map, path, url)
    map.record(path, NotionPublish::Manifest::Entry.new(
                       id: "p1", url: url, parent: nil, properties: [],
                       source_sha256: nil, notion_sha256: nil, published_at: nil
                     ))
  end

  def rewrite(body, registry, dir)
    links = NotionPublish::Links.new(registry: registry, base_dir: dir)
    [links.rewrite(body), links.unresolved]
  end

  def test_a_link_to_a_published_sibling_is_rewritten
    with_registry do |registry, dir|
      record(registry, File.join(dir, "data-management-policy.md"), "https://notion.so/DATA")

      out, = rewrite("See the [Data Management Policy](data-management-policy.md).\n", registry, dir)

      assert_equal "See the [Data Management Policy](https://notion.so/DATA).\n", out
    end
  end

  def test_every_occurrence_is_rewritten
    with_registry do |registry, dir|
      record(registry, File.join(dir, "a.md"), "https://notion.so/A")

      out, = rewrite("[one](a.md) and [two](a.md)\n", registry, dir)

      assert_equal "[one](https://notion.so/A) and [two](https://notion.so/A)\n", out
    end
  end

  # Notion turns a relative target into https://<target>, a hostname nobody
  # owns, so an unresolved link has to be reported rather than shipped quietly.
  def test_an_unpublished_target_is_reported_and_left_alone
    with_registry do |registry, dir|
      out, unresolved = rewrite("[x](not-yet.md)\n", registry, dir)

      assert_equal "[x](not-yet.md)\n", out
      assert_equal ["not-yet.md"], unresolved
      assert_equal "https://not-yet.md", NotionPublish::Links.mangled("not-yet.md")
    end
  end

  def test_absolute_links_are_untouched
    with_registry do |registry, dir|
      out, unresolved = rewrite("[a](https://example.com) [b](mailto:x@y.z) [c](#anchor)\n", registry, dir)

      assert_equal "[a](https://example.com) [b](mailto:x@y.z) [c](#anchor)\n", out
      assert_empty unresolved
    end
  end

  def test_images_are_not_treated_as_links
    with_registry do |registry, dir|
      out, unresolved = rewrite("![diagram](diagram.png)\n", registry, dir)

      assert_equal "![diagram](diagram.png)\n", out
      assert_empty unresolved
    end
  end

  def test_a_fragment_survives_the_rewrite
    with_registry do |registry, dir|
      record(registry, File.join(dir, "a.md"), "https://notion.so/A")

      out, = rewrite("[x](a.md#section-3)\n", registry, dir)

      assert_equal "[x](https://notion.so/A#section-3)\n", out
    end
  end

  def test_links_inside_fenced_code_are_left_alone
    with_registry do |registry, dir|
      record(registry, File.join(dir, "a.md"), "https://notion.so/A")
      body = "```\n[x](a.md)\n```\n"

      out, = rewrite(body, registry, dir)

      assert_equal body, out
    end
  end

  def test_paths_in_subdirectories_resolve
    with_registry do |registry, dir|
      record(registry, File.join(dir, "sub", "a.md"), "https://notion.so/A")

      out, = rewrite("[x](sub/a.md)\n", registry, dir)

      assert_equal "[x](https://notion.so/A)\n", out
    end
  end

  # Keys are stored relative to the registry file so a checkout can move.
  def test_the_registry_stores_relative_keys
    with_registry do |registry, dir|
      record(registry, File.join(dir, "a.md"), "https://notion.so/A")

      assert_equal("p1", registry.pages["a.md"]["id"])
      assert_equal(["a.md"], registry.pages.keys)
      assert_equal "https://notion.so/A", NotionPublish::Manifest.new(registry.path).url_for(File.join(dir, "a.md"))
    end
  end
end
