# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "stringio"
require "tmpdir"
require "webmock/minitest"

require "notion_publish"

module StubbingHelpers
  API = "https://api.notion.com"
  TOKEN = "ntn_test_token"

  def client(token: TOKEN)
    NotionPublish::Client.new(token: token, sleeper: ->(_) {})
  end

  def stub_me(name: "Test Connection", type: "bot", owner_type: "workspace")
    bot = { "owner" => { "type" => owner_type } }
    bot["owner"]["user"] = { "object" => "user", "name" => "A Person" } if owner_type == "user"
    stub_request(:get, "#{API}/v1/users/me")
      .to_return(status: 200, body: JSON.generate(
        "object" => "user", "id" => "user-1", "name" => name, "type" => type, "bot" => bot
      ))
  end

  def stub_notion(method, path, status:, body:)
    stub_request(method, "#{API}#{path}")
      .to_return(status: status, body: JSON.generate(body), headers: { "Content-Type" => "application/json" })
  end

  def stub_missing(method, path, id)
    stub_notion(method, path, status: 404, body: {
                  "object" => "error", "status" => 404, "code" => "object_not_found",
                  "message" => "Could not find with ID: #{id}.",
                  "additional_data" => { "integration_id" => "int-1" }
                })
  end

  def stub_block(id, type, payload)
    stub_notion(:get, "/v1/blocks/#{id}", status: 200, body: {
                  "object" => "block", "id" => id, "type" => type, type => payload
                })
  end

  def rich(text)
    [{ "type" => "text", "plain_text" => text }]
  end
end

module CLIHelpers
  # Runs the CLI in-process and returns [exit_code, stdout, stderr].
  def run_cli(argv, token: StubbingHelpers::TOKEN, stdin: StringIO.new)
    out = StringIO.new
    err = StringIO.new
    cli = NotionPublish::CLI.new(stdout: out, stderr: err, stdin: stdin, client: token && client(token: token))
    code = with_env("NOTION_API_TOKEN" => token, "NOTION_API_KEY" => nil) { cli.run(argv) }
    [code, out.string, err.string]
  end

  def with_env(vars)
    previous = vars.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    previous.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def with_markdown(content, name: "example.md")
    Dir.mktmpdir do |dir|
      path = File.join(dir, name)
      File.write(path, content)
      yield path
    end
  end
end

module Minitest
  class Test
    include StubbingHelpers
    include CLIHelpers
  end
end
