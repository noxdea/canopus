# frozen_string_literal: true

sadr_path = ENV["SADR_PATH"]
sadr_path ? require(File.expand_path("lib/sadr", sadr_path)) : require("sadr")

module Canopus
  module LSP
    Error = Sadr::Error
    Timeout = Sadr::Timeout
    ServerError = Sadr::ServerError
    Future = Sadr::Future
    Transport = Sadr::Transport

    module Protocol
      module_function

      def uri(path) = Sadr::Protocol.uri(path)
      def path(uri) = Sadr::Protocol.path(uri)
      def offset(index, position) = Sadr::Protocol.offset(index, position)
      def semantic_delta(data, edits) = Sadr::Protocol.semantic_delta(data, edits)
      def diagnostics(values) = Sadr::Protocol.diagnostics(values)
      def uint?(value) = Sadr::Protocol.uint?(value)

      def position(index, offset)
        point = Sadr::Protocol.position(index, offset)
        {line: point.line, character: point.character}
      end

      def range(index, byte_range)
        value = Sadr::Protocol.range(index, byte_range)
        {start: {line: value.start.line, character: value.start.character},
         end: {line: value.end.line, character: value.end.character}}
      end

      def semantic_tokens(data, legend: nil)
        Sadr::Protocol.semantic_tokens(data, legend: legend).map(&:to_h)
      end
    end

    class Client < Sadr::Client
      POSITION_METHODS = {
        "completion" => :completion,
        "hover" => :hover,
        "definition" => :definition,
        "typeDefinition" => :type_definition,
        "implementation" => :implementation,
        "signatureHelp" => :signature_help
      }.freeze

      def initialize(**options)
        super
        @buffer_subscriptions = {}
      end

      def start(timeout: 10)
        super
        self
      end

      def open_document(buffer, language_id:)
        raise Error, "LSP document needs a path" unless buffer.path

        uri = Protocol.uri(buffer.path)
        @buffer_subscriptions.delete(uri)&.detach
        open(Sadr::Document.new(uri: uri, language_id: language_id, version: buffer.version, text: buffer.text))
        @buffer_subscriptions[uri] = buffer.on_edit { |patch| change_document(uri, buffer, patch) }
        uri
      end

      def close_document(uri)
        @buffer_subscriptions.delete(uri)&.detach
        close(uri)
      end

      def save_document(uri) = save(uri)

      def at(method, buffer, offset, **params)
        Sadr::Client.instance_method(POSITION_METHODS.fetch(method)).bind(self).call(
          Protocol.uri(buffer.path), Sadr::Protocol.position(buffer.rope, offset), **params)
      end

      POSITION_METHODS.each_key do |method|
        define_method(method) { |buffer, offset, **params| at(method, buffer, offset, **params) }
      end

      def references(buffer, offset, **params)
        include_declaration = params.dig(:context, :includeDeclaration)
        super(Protocol.uri(buffer.path), Sadr::Protocol.position(buffer.rope, offset),
          include_declaration: include_declaration.nil? ? true : include_declaration)
      end

      def rename(buffer, offset, **params)
        super(Protocol.uri(buffer.path), Sadr::Protocol.position(buffer.rope, offset), params.fetch(:newName))
      end

      def documentSymbol(buffer, **) = document_symbol(Protocol.uri(buffer.path))

      def formatting(buffer, **params)
        super(Protocol.uri(buffer.path), params.fetch(:options))
      end

      def codeAction(buffer, **params)
        code_action(Protocol.uri(buffer.path), sadr_range(params.fetch(:range)), params.fetch(:context))
      end

      def inlayHint(buffer, **params)
        inlay_hint(Protocol.uri(buffer.path), sadr_range(params.fetch(:range)))
      end

      def codeLens(buffer, **) = code_lens(Protocol.uri(buffer.path))
      def diagnostic(buffer, **) = super(Protocol.uri(buffer.path))

      def semantic_tokens(buffer)
        super(Protocol.uri(buffer.path), version: buffer.version).map(&:to_h)
      end

      def apply_text_edits(buffer, edits)
        buffer.edit(Sadr::Protocol.text_edits(buffer.rope, edits), kind: :lsp)
      end

      def stop
        @buffer_subscriptions.each_value(&:detach)
        @buffer_subscriptions.clear
        super
      end

      private

      def sadr_range(value)
        start = value.fetch(:start) { value.fetch("start") }
        finish = value.fetch(:end) { value.fetch("end") }
        Sadr::Range_.new(start: sadr_position(start), end: sadr_position(finish))
      end

      def sadr_position(value)
        Sadr::Position.new(line: value.fetch(:line) { value.fetch("line") },
          character: value.fetch(:character) { value.fetch("character") })
      end

      def change_document(uri, buffer, patch)
        changes = if patch.is_a?(Patch)
          patch.edits.reverse.map do |edit|
            Sadr::ContentChange.new(range: Sadr::Protocol.range(patch.before, edit.old_range), text: edit.new_text)
          end
        else
          [Sadr::ContentChange.new(range: nil, text: buffer.text)]
        end
        change(uri, buffer.version, changes)
      rescue Error => error
        report_error(error)
      end
    end
  end
end
