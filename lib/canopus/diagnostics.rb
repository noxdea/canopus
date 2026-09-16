# frozen_string_literal: true

require "json"
require "sadr"

module Canopus
  module Diagnostics
    SOURCES = %i[lsp task test].freeze
    SEVERITIES = {error: 1, warning: 2, information: 3, hint: 4}.freeze
    URI_LIMIT = 16_384
    MESSAGE_LIMIT = 4_096
    PUBLICATION_LIMIT = 10_000
    TOTAL_LIMIT = 100_000
    TOTAL_BYTES_LIMIT = 32 << 20
    ITEM_BYTES_LIMIT = 1 << 20
    VALUE_DEPTH_LIMIT = 100

    Entry = Data.define(:source, :uri, :diagnostic)

    class Registry
      attr_reader :version

      def initialize(&on_change)
        @entries = {}
        @sizes = {}
        @counts = SEVERITIES.keys.to_h { |severity| [severity, 0] }
        @total = @bytes = 0
        @lock = Mutex.new
        @on_change = on_change
        @version = 0
      end

      def publish(source, uri, diagnostics)
        source = normalize_source(source)
        uri = normalize_uri(uri)
        values, bytes = normalize_diagnostics(diagnostics)
        @lock.synchronize do
          key = [source, uri]
          previous = @entries.fetch(key, [])
          total = @total - previous.length + values.length
          raise ArgumentError, "too many diagnostics" if total > TOTAL_LIMIT
          total_bytes = @bytes - @sizes.fetch(key, 0) + bytes
          raise ArgumentError, "diagnostics use too much memory" if total_bytes > TOTAL_BYTES_LIMIT

          previous.each { |diagnostic| @counts[SEVERITIES.key(diagnostic.fetch("severity", 1))] -= 1 }
          values.each { |diagnostic| @counts[SEVERITIES.key(diagnostic.fetch("severity", 1))] += 1 }
          if values.empty?
            @entries.delete(key)
            @sizes.delete(key)
          else
            @entries[key] = values
            @sizes[key] = bytes
          end
          @total, @bytes = total, total_bytes
          @version += 1
        end
        @on_change&.call(uri)
        values
      end

      def for_uri(uri)
        uri = normalize_uri(uri)
        @lock.synchronize do
          @entries.flat_map do |(source, current), diagnostics|
            current == uri ? diagnostics.map { |diagnostic| Entry.new(source, current, diagnostic).freeze } : []
          end.freeze
        end
      end

      def all(severity: nil, source: nil)
        severity = normalize_severity(severity) if severity
        source = normalize_source(source) if source
        @lock.synchronize do
          @entries.flat_map do |(entry_source, uri), diagnostics|
            next [] if source && source != entry_source

            diagnostics.filter_map do |diagnostic|
              next if severity && diagnostic.fetch("severity", 1) != severity
              Entry.new(entry_source, uri, diagnostic).freeze
            end
          end.freeze
        end
      end

      def counts
        @lock.synchronize { @counts.dup.freeze }
      end

      private

      def normalize_source(source)
        raise ArgumentError, "invalid diagnostic source" unless SOURCES.include?(source)
        source
      end

      def normalize_uri(uri)
        valid = uri.is_a?(String) && uri.encoding == Encoding::UTF_8 && uri.valid_encoding? &&
          uri.bytesize <= URI_LIMIT && !uri.include?("\0")
        raise ArgumentError, "invalid diagnostic URI" unless valid
        Sadr::Protocol.path(uri)
        uri.dup.freeze
      rescue Sadr::Error
        raise ArgumentError, "invalid diagnostic URI"
      end

      def normalize_severity(severity)
        severity = SEVERITIES.fetch(severity, severity) if severity.is_a?(Symbol)
        raise ArgumentError, "invalid diagnostic severity" unless severity.is_a?(Integer) && severity.between?(1, 4)
        severity
      end

      def normalize_diagnostics(diagnostics)
        unless diagnostics.is_a?(Array) && diagnostics.length <= PUBLICATION_LIMIT
          raise ArgumentError, "invalid diagnostics"
        end
        Sadr::Protocol.diagnostics(diagnostics)
        bytes = 0
        values = diagnostics.map do |diagnostic|
          message = diagnostic.fetch("message")
          valid = message.encoding == Encoding::UTF_8 && message.valid_encoding? &&
            message.bytesize <= MESSAGE_LIMIT && !message.include?("\0")
          raise ArgumentError, "invalid diagnostic message" unless valid

          validate_value(diagnostic)
          encoded = JSON.generate(diagnostic)
          raise ArgumentError, "diagnostic exceeds 1 MiB" if encoded.bytesize > ITEM_BYTES_LIMIT
          bytes += encoded.bytesize
          raise ArgumentError, "diagnostics use too much memory" if bytes > TOTAL_BYTES_LIMIT
          freeze_value(JSON.parse(encoded))
        end.freeze
        [values, bytes]
      rescue JSON::GeneratorError, JSON::ParserError, JSON::NestingError, Sadr::Error, KeyError, TypeError
        raise ArgumentError, "invalid diagnostics"
      end

      def freeze_value(value)
        value.each { |key, child| key.freeze; freeze_value(child) } if value.is_a?(Hash)
        value.each { |child| freeze_value(child) } if value.is_a?(Array)
        value.freeze
      end

      def validate_value(value, depth = 0)
        raise ArgumentError, "diagnostic is too deeply nested" if depth > VALUE_DEPTH_LIMIT

        case value
        when Hash
          raise ArgumentError, "invalid diagnostic" unless value.length <= PUBLICATION_LIMIT
          value.each do |key, child|
            validate_string(key)
            validate_value(child, depth + 1)
          end
        when Array
          raise ArgumentError, "invalid diagnostic" if value.length > PUBLICATION_LIMIT
          value.each { |child| validate_value(child, depth + 1) }
        when String then validate_string(value)
        when Float
          raise ArgumentError, "invalid diagnostic" unless value.finite?
        when NilClass, TrueClass, FalseClass, Integer
          nil
        else
          raise ArgumentError, "invalid diagnostic"
        end
      end

      def validate_string(value)
        valid = value.is_a?(String) && value.encoding == Encoding::UTF_8 && value.valid_encoding? &&
          value.bytesize <= MESSAGE_LIMIT && !value.include?("\0")
        raise ArgumentError, "invalid diagnostic text" unless valid
      end
    end
  end
end
