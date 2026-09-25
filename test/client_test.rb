# frozen_string_literal: true

require "test_helper"

class ClientTest < Minitest::Test
  def test_a_missing_token_is_reported_with_the_variables_to_set
    error = assert_raises(NotionPublish::MissingToken) { NotionPublish::Client.new(token: " ") }

    assert_includes error.message, "NOTION_API_TOKEN"
    assert_includes error.message, "NOTION_API_KEY"
  end

  def test_the_token_is_read_from_the_environment_in_order
    env = { "NOTION_API_TOKEN" => "", "NOTION_API_KEY" => "from-key" }

    assert_equal "from-key", NotionPublish::Client.token_from_env(env)
    assert_equal "first", NotionPublish::Client.token_from_env(env.merge("NOTION_API_TOKEN" => "first"))
  end

  def test_requests_carry_the_version_and_identify_the_tool
    stub_notion(:get, "/v1/users/me", status: 200, body: { "id" => "me" })

    client.get("/v1/users/me")

    assert_requested(:get, "#{StubbingHelpers::API}/v1/users/me", headers: {
                       "Authorization" => "Bearer #{StubbingHelpers::TOKEN}",
                       "Notion-Version" => NotionPublish::Client::API_VERSION,
                       "User-Agent" => NotionPublish::Client::USER_AGENT
                     })
  end

  def test_inspect_does_not_show_the_token
    refute_includes client.inspect, StubbingHelpers::TOKEN
  end

  def test_a_rate_limit_is_retried_after_the_delay_notion_asks_for
    slept = []
    stub_request(:get, "#{StubbingHelpers::API}/v1/users/me")
      .to_return({ status: 429, headers: { "Retry-After" => "3" }, body: "{}" },
                 { status: 200, body: JSON.generate("id" => "me") })

    result = NotionPublish::Client.new(token: "t", sleeper: ->(s) { slept << s }).get("/v1/users/me")

    assert_equal "me", result["id"]
    assert_equal [3.0], slept
  end

  def test_retries_give_up_and_raise
    stub_notion(:get, "/v1/users/me", status: 503, body: { "code" => "service_unavailable", "message" => "down" })

    error = assert_raises(NotionPublish::ApiError) { client.get("/v1/users/me") }

    assert_equal 503, error.status
    assert_requested :get, "#{StubbingHelpers::API}/v1/users/me", times: NotionPublish::Client::MAX_ATTEMPTS
  end

  def test_an_error_body_is_exposed_by_code
    stub_missing(:get, "/v1/pages/x", "x")

    error = assert_raises(NotionPublish::ApiError) { client.get("/v1/pages/x") }

    assert_predicate error, :not_found?
    assert_equal "int-1", error.integration_id
  end

  def test_get_all_follows_the_cursor
    base = "#{StubbingHelpers::API}/v1/users"
    stub_request(:get, "#{base}?page_size=100")
      .to_return(status: 200, body: JSON.generate("results" => [{ "id" => 1 }], "has_more" => true,
                                                  "next_cursor" => "c2"))
    stub_request(:get, "#{base}?page_size=100&start_cursor=c2")
      .to_return(status: 200, body: JSON.generate("results" => [{ "id" => 2 }], "has_more" => false))

    assert_equal([1, 2], client.get_all("/v1/users").map { |u| u["id"] })
  end
end
