# frozen_string_literal: true

source "https://rubygems.org"
gemspec
gem "wezen", "~> 0.1.0", require: false

path(ENV.fetch("ALKAID_PATH")) { gem "alkaid" } if ENV["ALKAID_PATH"]
path(ENV.fetch("GIENAH_PATH")) { gem "gienah" } if ENV["GIENAH_PATH"]
path(ENV.fetch("ZANIAH_PATH")) { gem "zaniah" } if ENV["ZANIAH_PATH"]
path(ENV.fetch("ANTARES_PATH")) { gem "antares" } if ENV["ANTARES_PATH"]
path(ENV.fetch("MEGREZ_PATH")) { gem "megrez" } if ENV["MEGREZ_PATH"]
path(ENV.fetch("MENKAR_PATH")) { gem "menkar" } if ENV["MENKAR_PATH"]
path(ENV.fetch("SADR_PATH")) { gem "sadr" } if ENV["SADR_PATH"]
path(ENV.fetch("SAIPH_PATH")) { gem "saiph" } if ENV["SAIPH_PATH"]
path(ENV.fetch("TARAZED_PATH")) { gem "tarazed" } if ENV["TARAZED_PATH"]

group :development, :test do
  gem "rake", "~> 13.0"
  gem "minitest", "~> 5.0"
  gem "rbs", "~> 3.9"
  gem "base64", "~> 0.2"
  gem "rspec-core", "~> 3.12"
  gem "diff-lcs", "~> 1.6"
  gem "fiddle", "~> 1.1"
end
