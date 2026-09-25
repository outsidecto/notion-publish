# frozen_string_literal: true

module NotionPublish
  # Notion returns object_not_found both for objects that do not exist and for
  # objects that exist but are not shared with the calling connection. The API
  # gives us no way to tell those apart, so these messages must not claim to.
  module Sharing
    module_function

    def unreachable(id:, title:, connection_name:, kind: nil)
      name = title && !title.empty? ? "#{title.inspect} (#{id})" : id.to_s
      <<~MSG.strip
        Cannot reach #{[kind, name].compact.join(' ')}.

        Either it does not exist, or it is not shared with the
        #{connection_name.inspect} connection. Notion returns the same error for
        both, so there is no way to tell which from here.

        #{instructions(kind)}
      MSG
    end

    def instructions(kind)
      case kind
      when "inline database"
        <<~MSG.strip
          An inline database has no connection menu of its own. Share the page it
          lives on:
            1. Open that page in Notion
            2. ••• menu (top right) -> Connections
            3. Add the connection
        MSG
      else
        <<~MSG.strip
          To share it:
            1. Open it in Notion
            2. ••• menu (top right) -> Connections
            3. Add the connection

          Anything nested underneath is shared automatically.

          An inline database has no menu of its own: share the page it sits on.
        MSG
      end
    end
  end
end
