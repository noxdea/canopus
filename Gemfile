# frozen_string_literal: true

source "https://rubygems.org"
gemspec

gem "sadr", path: ENV.fetch("SADR_PATH") if ENV["SADR_PATH"]

group :development, :test do
  gem "rake", "~> 13.0"
  gem "minitest", "~> 5.0"
  gem "rbs", "~> 3.9"
  gem "diff-lcs", "~> 1.6"
  gem "fiddle", "~> 1.1"
end
