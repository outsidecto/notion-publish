# frozen_string_literal: true

module NotionPublish
  # The languages a Notion code block can have.
  #
  # The block API refuses any other value, and the Markdown parser highlights
  # any label it does not know as JavaScript. So a fence's label is mapped to
  # one of these names, or to plain text.
  module Languages
    # As listed by the API's own validation error (checked 2026-10-12).
    NAMES = [
      "abap", "abc", "agda", "arduino", "ascii art", "assembly", "bash", "basic", "bnf", "c", "c#",
      "c++", "clojure", "coffeescript", "coq", "css", "dart", "dhall", "diff", "docker", "ebnf",
      "elixir", "elm", "erlang", "f#", "flow", "fortran", "gherkin", "glsl", "go", "graphql",
      "groovy", "haskell", "hcl", "html", "idris", "java", "javascript", "json", "julia", "kotlin",
      "latex", "less", "lisp", "livescript", "llvm ir", "lua", "makefile", "markdown", "markup",
      "matlab", "mathematica", "mermaid", "nix", "notion formula", "objective-c", "ocaml", "pascal",
      "perl", "php", "plain text", "powershell", "prolog", "protobuf", "purescript", "python", "r",
      "racket", "reason", "ruby", "rust", "sass", "scala", "scheme", "scss", "shell", "smalltalk",
      "solidity", "sql", "swift", "toml", "typescript", "vb.net", "verilog", "vhdl",
      "visual basic", "webassembly", "xml", "yaml", "java/c/c++/c#"
    ].freeze

    PLAIN_TEXT = "plain text"

    # Common short names, as GitHub and other renderers accept them.
    ALIASES = {
      "cjs" => "javascript", "console" => "shell", "cpp" => "c++", "cs" => "c#", "csharp" => "c#",
      "dockerfile" => "docker", "golang" => "go", "js" => "javascript", "jsonc" => "json",
      "jsx" => "javascript", "kt" => "kotlin", "md" => "markdown", "mjs" => "javascript",
      "objc" => "objective-c", "plaintext" => PLAIN_TEXT, "proto" => "protobuf",
      "ps1" => "powershell", "py" => "python", "rb" => "ruby", "rs" => "rust", "sh" => "shell",
      "shell-session" => "shell", "svg" => "xml", "terraform" => "hcl", "tex" => "latex",
      "text" => PLAIN_TEXT, "tf" => "hcl", "ts" => "typescript", "tsx" => "typescript",
      "txt" => PLAIN_TEXT, "yml" => "yaml", "zsh" => "shell"
    }.freeze

    module_function

    # The Notion name for a fence label, or plain text for none or one Notion
    # does not know.
    def notion_name(label)
      key = label.to_s.downcase
      return key if NAMES.include?(key)

      ALIASES.fetch(key, PLAIN_TEXT)
    end
  end
end
