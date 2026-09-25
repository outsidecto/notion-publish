# frozen_string_literal: true

module NotionPublish
  # Base for everything this gem raises on purpose. The CLI rescues this and
  # prints +message+ without a backtrace, so messages are user-facing prose.
  class Error < StandardError; end

  # No token was passed and none is set in the environment.
  class MissingToken < Error
    def initialize(var_names)
      super(<<~MSG.strip)
        No Notion API token found.

        Set one of these environment variables:
          #{var_names.join("\n  ")}

        Create a token at https://www.notion.so/profile/integrations
      MSG
    end
  end

  # A --parent or --page value that contains no Notion ID.
  class InvalidReference < Error
    def initialize(input)
      super(<<~MSG.strip)
        Could not find a Notion ID in: #{input}

        Expected a 32-character ID, a dashed UUID, or a Notion URL such as
        https://www.notion.so/Some-Page-32dab123cd45803f94c2d29516bd0188
      MSG
    end
  end

  # A settings file or the identity map could not be read.
  class ConfigError < Error; end

  # Raised for any non-2xx response. Carries the parsed Notion error body so
  # callers can branch on +code+ rather than parsing messages.
  class ApiError < Error
    attr_reader :status, :code, :notion_message, :additional_data, :request_id

    def initialize(status:, body:)
      @status = status
      @code = body["code"]
      @notion_message = body["message"]
      @additional_data = body["additional_data"] || {}
      @request_id = body["request_id"]
      super("Notion API error #{status} (#{@code}): #{@notion_message}")
    end

    def not_found? = code == "object_not_found"
    def unauthorized? = code == "unauthorized"
    def restricted? = code == "restricted_resource"
    def rate_limited? = code == "rate_limited"

    # The connection that was refused, when Notion tells us.
    def integration_id = additional_data["integration_id"]
  end

  # Still rate-limited after every retry.
  class RateLimited < ApiError; end
end
