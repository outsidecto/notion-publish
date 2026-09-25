# frozen_string_literal: true

require "test_helper"

class LogTest < Minitest::Test
  def test_level_one_logs_one_line_per_request
    stub_notion(:get, "/v1/pages/p1", status: 200, body: { "id" => "p1", "secret" => "body text" })

    lines = logged(1) { |c| c.get("/v1/pages/p1") }

    assert_equal 1, lines.length
    assert_match %r{\Anotion-publish: GET /v1/pages/p1 -> 200 \(\d+ ms\)\z}, lines.first
  end

  def test_level_two_adds_shortened_bodies
    stub_notion(:post, "/v1/search", status: 200, body: { "results" => ["x" * 1000] })

    lines = logged(2) { |c| c.post("/v1/search", { "query" => "Policies" }) }

    assert_includes lines, 'notion-publish:   > {"query":"Policies"}'
    response = lines.find { |l| l.include?("  < ") }

    assert_includes response, "chars)"
    assert_operator response.length, :<, 400
  end

  def test_the_token_is_never_logged
    stub_notion(:get, "/v1/users/me", status: 200, body: { "name" => "Bot" })

    lines = logged(2) { |c| c.get("/v1/users/me") }

    refute(lines.any? { |l| l.include?(StubbingHelpers::TOKEN) })
  end

  def test_retries_are_logged
    stub_request(:get, "#{StubbingHelpers::API}/v1/users/me")
      .to_return({ status: 429, headers: { "Retry-After" => "2" }, body: "{}" },
                 { status: 200, body: JSON.generate("id" => "me") })

    lines = logged(1) { |c| c.get("/v1/users/me") }

    assert_includes lines, "notion-publish:   429: retrying in 2.0s (attempt 2 of 4)"
  end

  def test_the_workspace_is_named_once
    stub_notion(:get, "/v1/users/me", status: 200, body: { "name" => "Bot", "bot" => { "workspace_name" => "Acme" } })

    lines = logged(1) do |c|
      c.me
      c.me
    end

    assert_equal(1, lines.count { |l| l.include?('authenticated as "Bot" in "Acme"') })
  end

  def test_verbose_flags_reach_the_client_and_leave_stdout_alone
    stub_me
    out = StringIO.new
    err = StringIO.new
    cli = NotionPublish::CLI.new(stdout: out, stderr: err)

    code = with_env("NOTION_API_TOKEN" => "ntn_from_env", "NOTION_API_KEY" => nil) { cli.run(%w[--whoami -vvv]) }

    assert_equal NotionPublish::CLI::OK, code
    assert_includes err.string, "GET /v1/users/me -> 200"
    assert_includes err.string, "  < "
    refute_includes out.string, "notion-publish: GET"
  end

  # status never needs /v1/users/me, but under -v the workspace is named
  # anyway, since that is the first thing to check.
  # -v only lists every file; it does not log requests.
  def test_a_single_v_logs_no_requests
    stub_me
    err = StringIO.new
    cli = NotionPublish::CLI.new(stdout: StringIO.new, stderr: err)

    with_env("NOTION_API_TOKEN" => "ntn_from_env", "NOTION_API_KEY" => nil) { cli.run(%w[--whoami -v]) }

    refute_includes err.string, "GET /v1/users/me"
  end

  def test_verbose_names_the_workspace_even_when_the_command_would_not_ask
    stub_notion(:get, "/v1/users/me", status: 200, body: { "name" => "Bot", "bot" => { "workspace_name" => "Acme" } })
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "notion-publish-manifest.yml"), "pages: {}\n")
      err = StringIO.new
      cli = NotionPublish::CLI.new(stdout: StringIO.new, stderr: err)

      with_env("NOTION_API_TOKEN" => "ntn_from_env", "NOTION_API_KEY" => nil) { cli.run(["status", dir, "-vv"]) }

      assert_includes err.string, 'authenticated as "Bot" in "Acme"'
    end
  end

  private

  def logged(level)
    io = StringIO.new
    yield NotionPublish::Client.new(token: StubbingHelpers::TOKEN, sleeper: ->(_) {},
                                    log: NotionPublish::Log.new(io, level))
    io.string.lines.map(&:chomp)
  end
end
