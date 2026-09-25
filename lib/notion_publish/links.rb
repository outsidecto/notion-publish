# frozen_string_literal: true

module NotionPublish
  # Rewrites links between documents in the same set.
  #
  # A relative link is not merely dead in Notion: the API turns
  # `](data-management-policy.md)` into `](https://data-management-policy.md)`,
  # an absolute URL to a hostname nobody owns. Rewriting them to the published
  # Notion URL before sending avoids that entirely; anything still unresolved is
  # reported rather than shipped.
  class Links
    FENCE = /\A\s*(?:`{3,}|~{3,})/
    # A link, not an image: the negative lookbehind drops ![alt](...).
    LINK = /(?<!!)\[([^\]]*)\]\(\s*([^)\s]+?)\s*(?:"[^"]*")?\s*\)/
    ABSOLUTE = %r{\A(?:https?://|mailto:|#)}i

    # What a relative target becomes once Notion has mangled it. Used by the
    # relink pass to find links on an already-published page.
    def self.mangled(target) = "https://#{target}"

    attr_reader :unresolved

    def initialize(registry:, base_dir:)
      @registry = registry
      @base_dir = base_dir
      @unresolved = []
    end

    def rewrite(body)
      in_fence = false

      body.to_s.lines.map do |line|
        if line.match?(FENCE)
          in_fence = !in_fence
          next line
        end
        next line if in_fence

        line.gsub(LINK) do
          text = Regexp.last_match(1)
          target = Regexp.last_match(2)
          replacement = resolve(target)
          replacement ? "[#{text}](#{replacement})" : Regexp.last_match(0)
        end
      end.join
    end

    private

    def resolve(target)
      return nil if target.match?(ABSOLUTE)

      path, fragment = target.split("#", 2)
      return nil if path.to_s.empty?

      url = @registry.url_for(File.expand_path(path, @base_dir))
      unless url
        @unresolved << target
        return nil
      end

      fragment ? "#{url}##{fragment}" : url
    end
  end
end
