# frozen_string_literal: true

# Real language-server oracle, not a mock. All project writes stay in mktmpdir.
# RUBY_LSP, RUST_ANALYZER, TYPESCRIPT_LANGUAGE_SERVER and GOPLS select executables.
require "tmpdir"
require "fileutils"
require "rbconfig"
require "json"
require_relative "../lib/canopus"
require_relative "../lib/canopus/lsp"

module LspInterop
  module_function
  def present?(value)
    value && value != [] && value != {} && (!value.is_a?(Hash) || !value.key?("items") || !value["items"].empty?)
  end

  def await_stable
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
    begin
      yield.await(timeout: 30)
    rescue Canopus::Lsp::ServerError => error
      # Index/document updates may cancel a read request according to LSP.
      raise unless [-32801, -32802].include?(error.code) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      sleep(0.1)
      retry
    end
  end

  def run(language)
    Dir.mktmpdir("canopus-lsp-#{language}-") do |root|
      env = {"BUNDLE_GEMFILE" => nil, "BUNDLE_BIN_PATH" => nil, "RUBYOPT" => nil, "GOTOOLCHAIN" => "local", "GOTELEMETRY" => "off"}
      options = {}
      case language
      when "ruby"
        # An explicit local bundle keeps the genuine ruby-lsp executable from
        # composing/downloading an implicit bundle before speaking the protocol.
        File.write(File.join(root, "Gemfile"), "source 'https://rubygems.org'\ngem 'ruby-lsp'\n")
        env["BUNDLE_GEMFILE"] = File.join(root, "Gemfile")
        bundle = File.join(RbConfig::CONFIG.fetch("bindir"), "bundle")
        output, status = Open3.capture2e(env, RbConfig.ruby, bundle, "lock", "--local", chdir: root)
        raise "cannot lock local Ruby LSP dependencies: #{output}" unless status.success?
        command = [RbConfig.ruby, bundle, "exec", ENV.fetch("RUBY_LSP", "ruby-lsp")]
        filename = "example.rb"
        source = "class Greeter\n  def greet(value)\n    value + 1\n  end\nend\nexample = Greeter.new\nexample.greet(1)\n"
        needle = "Greeter.new"
        options = {formatter: "none", linters: []}
      when "rust"
        File.write(File.join(root, "Cargo.toml"), "[package]\nname = 'interop_fixture'\nversion = '0.1.0'\nedition = '2021'\n")
        FileUtils.mkdir_p(File.join(root, "src"))
        command = [ENV.fetch("RUST_ANALYZER", "rust-analyzer")]
        filename = "src/lib.rs"
        source = "pub fn greet(value: i32) -> i32 { value + 1 }\npub fn run() -> i32 { let 日本 = 1; greet(日本) }\n"
        needle = "greet(日本)"
        options = {checkOnSave: false, cargo: {buildScripts: {enable: false}}, procMacro: {enable: false}}
      when "typescript"
        File.write(File.join(root, "tsconfig.json"), JSON.generate(compilerOptions: {strict: true, target: "ES2020"}, include: ["*.ts"]))
        command = [ENV.fetch("TYPESCRIPT_LANGUAGE_SERVER", "typescript-language-server"), "--stdio"]
        options = {tsserver: {path: ENV["TSSERVER_PATH"]}} if ENV["TSSERVER_PATH"]
        filename = "example.ts"
        source = "export function greet(value:number):number{return value+1;}\nconst 日本 = 1;\nconst result = greet(日本);\n"
        needle = "greet(日本)"
      when "go"
        env.merge!("GOCACHE" => File.join(root, ".gocache"), "GOPATH" => File.join(root, ".gopath"), "GOMODCACHE" => File.join(root, ".gomodcache"), "GOWORK" => "off", "GOPROXY" => "off")
        options = {semanticTokens: true, hints: {parameterNames: true}}
        File.write(File.join(root, "go.mod"), "module example.com/interop\n\ngo 1.22\n")
        command = [ENV.fetch("GOPLS", "gopls")]
        filename = "example.go"
        source = "package fixture\nfunc greet(value int) int { return value + 1 }\nfunc run() int { 日本 := 1; return greet(日本) }\n"
        needle = "greet(日本)"
      else
        raise ArgumentError, "unknown language #{language}"
      end
      path = File.join(root, filename)
      File.write(path, source)
      client = Canopus::Lsp::Client.new(command: command, root: root, env: env, initialization_options: options, restart: false)
      logs = []
      client.on("window/logMessage") { |message| logs << message; logs.shift if logs.length > 20 }
      client.start(timeout: 60)
      buffer = Canopus::Buffer.new(source, path: path)
      uri = client.open_document(buffer, language_id: language)
      offset = source.b.index(needle.b) + 2
      results = {server: client.server_info, encoding: client.position_encoding, capabilities: client.capabilities.keys.sort, checks: {}}
      if language == "go" && results[:server]["version"].start_with?("{")
        results[:server] = results[:server].merge("version" => JSON.parse(results[:server]["version"]).fetch("Version"))
      elsif results[:server].nil?
        version, status = Open3.capture2(command.first, "--version")
        raise "cannot read server version" unless status.success?
        results[:server] = {"name" => File.basename(command.first), "version" => version.strip}
      end
      # Indexing is asynchronous; retry actual requests until nonempty or deadline.
      {hover: "hoverProvider", completion: "completionProvider", definition: "definitionProvider", documentSymbol: "documentSymbolProvider", references: "referencesProvider", rename: "renameProvider", formatting: "documentFormattingProvider", signatureHelp: "signatureHelpProvider", codeAction: "codeActionProvider", codeLens: "codeLensProvider", inlayHint: "inlayHintProvider", diagnostic: "diagnosticProvider"}.each do |feature, capability|
        next unless client.supports?(capability)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
        value = nil
        loop do
          future = case feature
          when :documentSymbol, :codeLens, :diagnostic then client.public_send(feature, buffer)
          when :formatting then client.formatting(buffer, options: {tabSize: 2, insertSpaces: true})
          when :codeAction then client.codeAction(buffer, range: Canopus::Lsp::Protocol.range(buffer.rope, 0...buffer.rope.bytesize), context: {diagnostics: []})
          when :inlayHint then client.inlayHint(buffer, range: Canopus::Lsp::Protocol.range(buffer.rope, 0...buffer.rope.bytesize))
          when :references then client.references(buffer, offset, context: {includeDeclaration: true})
          when :rename then client.rename(buffer, offset, newName: "greeting")
          when :signatureHelp
            call = source.b.rindex("greet(".b)
            client.signatureHelp(buffer, call + "greet(".bytesize)
          else client.public_send(feature, buffer, offset)
          end
          begin
            value = future.await(timeout: 30)
          rescue Canopus::Lsp::ServerError => error
            raise unless ([-32801, -32802].include?(error.code) || (language == "go" && error.message.include?("no package metadata"))) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
            sleep(0.2)
            next
          end
          break if present?(value) || !%i[hover completion definition documentSymbol].include?(feature)
          raise "#{language} #{feature} stayed empty" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          sleep(0.2)
        end
        results[:checks][feature] = {nonempty: !!present?(value), bytes: JSON.generate(value).bytesize}
        if feature == :completion && client.capabilities.dig("completionProvider", "resolveProvider")
          item = value.is_a?(Hash) ? value.fetch("items").first : value.first
          resolved = client.resolve_completion(item).await
          raise "#{language} completion resolve failed" unless resolved.is_a?(Hash) && resolved["label"].is_a?(String)
          results[:checks][:completion_resolve] = true
        elsif feature == :codeAction && client.capabilities["codeActionProvider"].is_a?(Hash) && client.capabilities.dig("codeActionProvider", "resolveProvider")
          action = value&.find { |item| item.is_a?(Hash) && item["data"] && item["kind"] }
          if action
            resolved = client.resolve_code_action(action).await
            raise "#{language} code action resolve failed" unless resolved.is_a?(Hash) && resolved["title"].is_a?(String)
            results[:checks][:code_action_resolve] = true
          end
        end
      end
      if client.supports?("workspaceSymbolProvider")
        value = await_stable { client.workspace_symbols(language == "ruby" ? "Greeter" : "greet") }
        raise "#{language} workspace symbols empty" unless present?(value)
        results[:checks][:workspace_symbols] = {nonempty: true, bytes: JSON.generate(value).bytesize}
      end
      if client.supports?("semanticTokensProvider")
        first = client.semantic_tokens(buffer)
        buffer.edit([[buffer.rope.bytesize...buffer.rope.bytesize, "\n"]])
        second = client.semantic_tokens(buffer)
        raise "#{language} semantic tokens empty" if first.empty? || second.empty?
        results[:checks][:semantic_tokens] = {initial: first.length, after_change: second.length, delta: client.capabilities.dig("semanticTokensProvider", "full").is_a?(Hash)}
      else
        buffer.edit([[buffer.rope.bytesize...buffer.rope.bytesize, "\n"]])
      end
      client.save_document(uri)
      results[:checks][:incremental_change] = buffer.version == 1
      results[:checks][:diagnostics_push] = client.diagnostics.key?(uri)
      invalid = case language
      when "ruby" then "def broken(\n"
      when "rust" then "pub fn broken() { let bad: i32 = \"wrong\"; }\n"
      when "typescript" then "const bad: number = \"wrong\";\n"
      when "go" then "var bad int = \"wrong\"\n"
      end
      buffer.edit([[buffer.rope.bytesize...buffer.rope.bytesize, invalid]])
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
      loop do
        diagnostics = if client.supports?("diagnosticProvider")
          await_stable { client.diagnostic(buffer) }&.fetch("items", [])
        else
          client.diagnostics[uri]
        end
        if diagnostics && !diagnostics.empty?
          results[:checks][:invalid_source_diagnostics] = {count: diagnostics.length, pull: client.supports?("diagnosticProvider")}
          break
        end
        raise "#{language} invalid source produced no diagnostics" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep(0.2)
      end
      results[:errors] = client.errors.map(&:message)
      client.close_document(uri)
      client.stop
      results[:checks][:shutdown] = client.state == :stopped && !client.transport.alive?
      puts JSON.generate(language: language, **results)
    rescue StandardError => error
      warn JSON.generate(language: language, error: "#{error.class}: #{error.message}", stderr: client&.transport&.stderr_lines&.last(20), server_logs: logs, client_errors: client&.errors&.map(&:message))
      raise
    ensure
      client&.stop
    end
  end
end

(ARGV.empty? ? %w[ruby rust typescript go] : ARGV).each { |language| LspInterop.run(language) }
