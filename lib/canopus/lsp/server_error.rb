# frozen_string_literal: true

module Canopus
  module LSP
    class ServerError < Error
      attr_reader :code, :data
      def initialize(error)
        @code, @data = error["code"], error["data"]
        super(error["message"])
      end
    end
  end
end
