# frozen_string_literal: true

source "https://rubygems.org"
gemspec

gem "alkaid", path: ENV.fetch("ALKAID_PATH") if ENV["ALKAID_PATH"]
gem "gienah", path: ENV.fetch("GIENAH_PATH") if ENV["GIENAH_PATH"]
gem "zaniah", path: ENV.fetch("ZANIAH_PATH") if ENV["ZANIAH_PATH"]
gem "antares", path: ENV.fetch("ANTARES_PATH") if ENV["ANTARES_PATH"]
gem "megrez", path: ENV.fetch("MEGREZ_PATH") if ENV["MEGREZ_PATH"]
gem "menkar", path: ENV.fetch("MENKAR_PATH") if ENV["MENKAR_PATH"]
gem "sadr", path: ENV.fetch("SADR_PATH") if ENV["SADR_PATH"]
gem "saiph", path: ENV.fetch("SAIPH_PATH") if ENV["SAIPH_PATH"]
gem "tarazed", path: ENV.fetch("TARAZED_PATH") if ENV["TARAZED_PATH"]

group :development, :test do
  gem "rake", "~> 13.0"
  gem "minitest", "~> 5.0"
  gem "rbs", "~> 3.9"
  gem "base64", "~> 0.2"
  gem "rspec-core", "~> 3.12"
  gem "diff-lcs", "~> 1.6"
  gem "fiddle", "~> 1.1"
end
