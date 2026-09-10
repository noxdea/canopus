# frozen_string_literal: true

require_relative "language/definition"
require_relative "language/symbol"

module Canopus
  module Language
    DEFINITIONS = [
      ["ruby", "ruby", %w[.rb .rake .gemspec Gemfile Rakefile], "#", /(?:^\s*(?:class|module|def|if|unless|case|while|until|for|begin)\b.*|(?:\bdo|[\[{(])(?:\s*\|[^|]*\|)?\s*)$/, /^\s*(?:end\b|else\b|elsif\b|rescue\b|ensure\b|[\]})])/, [["ruby-lsp"]]],
      ["javascript", "javascript", %w[.js .jsx .mjs .cjs], "//", /[\[{(]\s*$/, /^\s*[\]})]/, [["typescript-language-server", "--stdio"]]],
      ["typescript", "typescript", %w[.ts .tsx], "//", /[\[{(]\s*$/, /^\s*[\]})]/, [["typescript-language-server", "--stdio"]]],
      ["python", "python", %w[.py .pyi], "#", /:\s*(?:#.*)?$/, /^\s*(?:else|elif|except|finally)\b/, [["pyright-langserver", "--stdio"]]],
      ["rust", "rust", %w[.rs], "//", /[\[{(]\s*$/, /^\s*[\]})]/, [["rust-analyzer"]]],
      ["go", "go", %w[.go], "//", /[\[{(]\s*$/, /^\s*[\]})]/, [["gopls"]]],
      ["c", "c", %w[.c .h], "//", /[\[{(]\s*$/, /^\s*[\]})]/, [["clangd"]]],
      ["cpp", "cpp", %w[.cpp .hpp .cc .cxx], "//", /[\[{(]\s*$/, /^\s*[\]})]/, [["clangd"]]],
      ["json", "json", %w[.json .jsonc], "//", /[\[{]\s*$/, /^\s*[\]}]/, []],
      ["yaml", "yaml", %w[.yml .yaml], "#", /:\s*$/, /^\s*$/, []],
      ["toml", "toml", %w[.toml], "#", /[\[{]\s*$/, /^\s*[\]}]/, []],
      ["markdown", "markdown", %w[.md .markdown], "<!--", /\A\z/, /\A\z/, []],
      ["html", "html", %w[.html .erb], "<!--", /<[^\/>]+>\s*$/, /^\s*<\//, []],
      ["css", "css", %w[.css .scss], "/*", /\{\s*$/, /^\s*}/, []],
      ["shellscript", "shell", %w[.sh .bash .zsh], "#", /\b(?:then|do|case)\s*$/, /^\s*(?:fi|done|esac)\b/, []]
    ].map { |values| Definition.new(*values) }.freeze
    PLAIN = Definition.new("text", "plaintext", [], "#", /\A\z/, /\A\z/, [])
    def self.for_path(path)
      return PLAIN unless path
      extension, base = File.extname(path), File.basename(path)
      DEFINITIONS.find { |language| language.extensions.include?(extension) || language.extensions.include?(base) } || PLAIN
    end
    def self.executable?(name)
      paths = name.include?(File::SEPARATOR) ? [name] : ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |path| File.join(path, name) }
      paths.any? { |path| File.file?(path) && File.executable?(path) }
    end

  end
end

require_relative "language/background_analysis"
require_relative "language/document"
Canopus::Language.send(:private_constant, :BackgroundAnalysis)
require_relative "snippet"
