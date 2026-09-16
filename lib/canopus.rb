# frozen_string_literal: true

require_relative "canopus/version"
require_relative "canopus/data_compat"
require_relative "canopus/regexp_compat"
require_relative "canopus/match_data_compat"
require_relative "canopus/error"
require_relative "canopus/save_conflict"

require "denebola"
require "zaniah"
require "porrima"
require "thuban"
require_relative "canopus/command"
require_relative "canopus/panel"
require_relative "canopus/decoration"
require_relative "canopus/provider"
require_relative "canopus/patch"
require_relative "canopus/buffer"
require_relative "canopus/multi_buffer"
require_relative "canopus/display_map"
require_relative "canopus/editor"
require_relative "canopus/language"
require "spica"
require_relative "canopus/project"
require_relative "canopus/debug/configuration"
require_relative "canopus/debug/breakpoints"
megrez_path = ENV["MEGREZ_PATH"]
megrez_root = File.expand_path("..", __dir__)
megrez_path ? require(File.expand_path("lib/megrez", File.expand_path(megrez_path, megrez_root))) : require("megrez")
require_relative "canopus/debug/session"
require_relative "canopus/debug/panel"
require_relative "canopus/debug/console"
tarazed_path = ENV["TARAZED_PATH"]
tarazed_root = File.expand_path("..", __dir__)
tarazed_path ? require(File.expand_path("lib/tarazed", File.expand_path(tarazed_path, tarazed_root))) : require("tarazed")
require_relative "canopus/task/configuration"
require_relative "canopus/task/runner"
require_relative "canopus/workspace"
require_relative "canopus/plugins"
require_relative "canopus/controller"
