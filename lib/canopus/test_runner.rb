# frozen_string_literal: true

require_relative "data_compat"
require "thuban"
alkaid_path = ENV["ALKAID_PATH"]
alkaid_root = File.expand_path("../..", __dir__)
alkaid_path ? require(File.expand_path("lib/alkaid", File.expand_path(alkaid_path, alkaid_root))) : require("alkaid")

module Canopus
  module TestRunner
    Test = Data.define(:framework, :path, :name, :groups, :line, :column, :offset, :selector)
    Result = Data.define(:status, :path, :line, :message)
    MAX_PATH_BYTES = 16_384

    class << self
      def normalize_path(path)
        return unless path.is_a?(String) && path.bytesize <= MAX_PATH_BYTES && !path.include?("\0")

        value = path.encode(Encoding::UTF_8)
        value = value.tr(File::ALT_SEPARATOR, "/") if File::ALT_SEPARATOR
        return unless value.valid_encoding? && !value.start_with?("/")
        return if value.split("/").any? { |part| part.empty? || part == "." || part == ".." }

        value.freeze
      rescue EncodingError
        nil
      end

      def framework_for(path)
        path = normalize_path(path)
        return unless path&.end_with?(".rb")

        name = File.basename(path)
        return :rspec if name.end_with?("_spec.rb")
        return :minitest if name.end_with?("_test.rb") || name.start_with?("test_")

        path.split("/")[0...-1].reverse_each do |directory|
          return :minitest if directory == "test"
          return :rspec if directory == "spec"
        end
        nil
      end
    end
  end
end

require_relative "test_runner/bounded_ignore"
require_relative "test_runner/safe_walker"
require_relative "test_runner/minitest"
require_relative "test_runner/rspec"
require_relative "test_runner/discovery"
require_relative "test_runner/execution"

Canopus::TestRunner.private_constant :SafeWalker
