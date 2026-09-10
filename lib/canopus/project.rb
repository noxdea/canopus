# frozen_string_literal: true

require "set"
require "fileutils"
require "tempfile"

module Canopus
  class Project
    attr_reader :root

    def initialize(root)
      @root = File.realpath(root)
      raise ArgumentError, "project root must be a directory" unless File.directory?(@root)
    end

    def path(relative)
      absolute = File.expand_path(relative, root)
      raise ArgumentError, "path outside project" unless absolute == root || absolute.start_with?(root + File::SEPARATOR)
      absolute
    end

    # Paths are relative to root, sorted, and never include .git directories.
    # Directory symlinks are opt-in and visited at most once per inode.
    def files(include_hidden: true, follow_symlinks: false, include_symlinks: false, include_directories: false, extensions: nil, max_size: nil)
      return enum_for(__method__, include_hidden: include_hidden, follow_symlinks: follow_symlinks,
        include_symlinks: include_symlinks, include_directories: include_directories, extensions: extensions, max_size: max_size) unless block_given?
      extensions = extensions&.map { |extension| extension.start_with?(".") ? extension : ".#{extension}" }&.to_set
      visited = Set.new
      base_rules = IgnoreMatcher.new
      exclude = File.join(root, ".git", "info", "exclude")
      base_rules = base_rules.add(File.read(exclude), base: "") if File.file?(exclude)
      walk = lambda do |directory, rules|
        stat = File.stat(path(directory))
        return unless visited.add?([stat.dev, stat.ino])
        %w[.gitignore .ignore].each do |name|
          source = path(directory.empty? ? name : File.join(directory, name))
          rules = rules.add(File.read(source, encoding: "UTF-8"), base: directory) if File.file?(source)
        end
        Dir.children(path(directory)).sort.each do |name|
          next if name == ".git" || (!include_hidden && name.start_with?("."))
          relative = directory.empty? ? name : File.join(directory, name)
          next if relative == ".canopus/trash"
          absolute = path(relative)
          begin
            entry = File.lstat(absolute)
            symbolic = entry.symlink?
            if symbolic && !follow_symlinks
              next unless include_symlinks
              next if rules.ignored?(relative)
              next if extensions && !extensions.include?(File.extname(name))
              yield relative
              next
            end
            entry = File.stat(absolute) if symbolic
            next if rules.ignored?(relative, directory: entry.directory?)
            if entry.directory?
              yield relative + "/" if include_directories
              walk.call(relative, rules)
            elsif entry.file?
              next if max_size && entry.size > max_size
              next if extensions && !extensions.include?(File.extname(name))
              yield relative
            end
          rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
            next # An editor walk tolerates concurrent deletion and inaccessible files.
          end
        end
      end
      walk.call("", base_rules)
      self
    end

    def ignored?(relative, directory: File.directory?(path(relative)))
      pieces = relative.sub(%r{\A\./}, "").split("/")
      rules = IgnoreMatcher.new
      base = ""
      exclude = File.join(root, ".git", "info", "exclude")
      rules = rules.add(File.read(exclude), base: "") if File.file?(exclude)
      pieces.each_with_index do |piece, index|
        return true if piece == ".git"
        %w[.gitignore .ignore].each do |name|
          source = path(base.empty? ? name : File.join(base, name))
          rules = rules.add(File.read(source), base: base) if File.file?(source)
        end
        base = base.empty? ? piece : "#{base}/#{piece}"
        return true if rules.ignored?(base, directory: index < pieces.length - 1 || directory)
      end
      false
    end

    def search(pattern, **options, &block) = Search.new(self).call(pattern, **options, &block)
    def watcher(**options) = Watcher.new(self, **options)

    # Each file is replaced atomically; a concurrent write aborts that file.
    def replace(pattern, replacement, **options)
      expression = pattern.is_a?(Regexp) ? pattern : Regexp.new(Regexp.escape(pattern))
      searcher = Search.new(self)
      paths = searcher.call(expression, **options).map(&:path).uniq
      paths.to_h do |relative|
        absolute = path(relative)
        before = File.stat(absolute)
        text = File.read(absolute, encoding: "UTF-8")
        count, updated = Canopus.with_regexp_timeout(expression) do
          [text.scan(expression).length, text.gsub(expression, replacement)]
        end
        Tempfile.create([".canopus-", ".tmp"], File.dirname(absolute)) do |temp|
          temp.binmode
          temp.chmod(before.mode & 0o777)
          temp.write(updated)
          temp.flush
          temp.fsync
          temp.close
          current = File.stat(absolute)
          unless [before.ino, before.size, before.mtime, before.ctime] == [current.ino, current.size, current.mtime, current.ctime]
            raise IOError, "file changed during replacement: #{relative}"
          end
          File.rename(temp.path, absolute)
        end
        [relative, count]
      end
    end
  end
end

require_relative "project/ignore_matcher"
require_relative "project/search"
require_relative "project/watcher"
