# frozen_string_literal: true

ENV["MT_NO_PLUGINS"] = "1"
gem "minitest", "~> 6.0"
require "minitest/autorun"
require "minitest/mock"
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "canopus"
