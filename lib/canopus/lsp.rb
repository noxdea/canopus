# frozen_string_literal: true

require "json"
require "open3"
require "uri"
require "thread"

module Canopus
  module LSP; end
end

require_relative "lsp/error"
require_relative "lsp/timeout"
require_relative "lsp/server_error"
require_relative "lsp/protocol"
require_relative "lsp/future"
require_relative "lsp/future/subscription"
require_relative "lsp/transport"
require_relative "lsp/client"
