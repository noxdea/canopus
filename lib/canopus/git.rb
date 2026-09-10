# frozen_string_literal: true

require "fileutils"
require "find"
require "tempfile"
require_relative "project"
require_relative "git/object_database"
require_relative "git/index"
require_relative "git/diff"
require_relative "git/status"
require_relative "git/blame"
require_relative "git/commit"
require_relative "git/tree_entry"

require_relative "git/repository"
