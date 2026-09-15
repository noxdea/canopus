# frozen_string_literal: true

source "https://rubygems.org"
gemspec

gem "alkaid", path: ENV.fetch("ALKAID_PATH") if ENV["ALKAID_PATH"]
gem "antares", path: ENV.fetch("ANTARES_PATH") if ENV["ANTARES_PATH"]
gem "sadr", path: ENV.fetch("SADR_PATH") if ENV["SADR_PATH"]
gem "tarazed", path: ENV.fetch("TARAZED_PATH") if ENV["TARAZED_PATH"]

group :development, :test do
  gem "rake", "~> 13.0"
  gem "minitest", "~> 5.0"
  gem "rbs", "~> 3.9"
  gem "diff-lcs", "~> 1.6"
  gem "fiddle", "~> 1.1"
end
