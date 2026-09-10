# frozen_string_literal: true

require_relative "../regexp_compat"
require_relative "../match_data_compat"

    # This protocol only connects this file to its own Ruby parent. Marshal is
    # never accepted from a file, network peer, plugin, or external executable.
module Canopus::Project::SearchWorker
  MAX_FILE_BYTES = 64 << 20
  MAX_FRAME_BYTES = MAX_FILE_BYTES + (64 << 10)
  READ_BYTES = 64 << 10
  MATCH_BATCH = 128

  def self.check_cancelled(callback)
    raise Cancelled if callback&.call
  end

  def self.write_frame(io, value)
    bytes = Marshal.dump(value)
    raise IOError, "search frame exceeds safety limit" if bytes.bytesize > MAX_FRAME_BYTES
    io.write([bytes.bytesize].pack("N"))
    io.write(bytes)
    io.flush
  end

  def self.read_frame(io)
    header = io.read(4)
    raise EOFError, "search worker ended before completion" unless header && header.bytesize == 4
    size = header.unpack1("N")
    raise IOError, "invalid search frame size" unless size.between?(1, MAX_FRAME_BYTES)
    bytes = io.read(size)
    raise EOFError, "truncated search frame" unless bytes && bytes.bytesize == size
    Marshal.load(bytes)
  rescue TypeError, ArgumentError => error
    raise IOError, "invalid search frame: #{error.message}"
  end

  def self.scan(root, paths, expression, max_size, limit, cancelled: nil)
    total = 0
    paths.each do |relative|
      check_cancelled(cancelled)
      absolute = File.expand_path(relative, root)
      raise ArgumentError, "path outside project" unless absolute.start_with?(root + File::SEPARATOR)
      source = read_source(absolute, max_size, cancelled)
      next unless source
      offset = 0
      source.each_line.with_index(1) do |line, number|
        check_cancelled(cancelled)
        matches, sent_line = [], false
        Canopus.with_regexp_timeout(expression) do
          line.to_enum(:scan, expression).each do
            match = Regexp.last_match
            check_cancelled(cancelled)
            unless sent_line
              yield [:line, relative, number, offset, line]
              sent_line = true
            end
            first = match.respond_to?(:bytebegin) ? match.bytebegin(0) : match.pre_match.bytesize
            matches << [match.begin(0) + 1, first, first + match[0].bytesize]
            total += 1
            if matches.length == MATCH_BATCH || (limit && total >= limit)
              yield [:matches, matches]
              matches = []
            end
            return if limit && total >= limit
          end
        end
        yield [:matches, matches] unless matches.empty?
        offset += line.bytesize
      end
    end
  end

  def self.read_source(path, max_size, cancelled)
    flags = File::RDONLY
    # Windows defines NONBLOCK as 1, which aliases WRONLY in File.open.
    flags |= File::NONBLOCK unless RUBY_PLATFORM.match?(/mswin|mingw/)
    File.open(path, flags) do |file|
      file.binmode
      return unless file.stat.file? && file.size <= max_size
      source = +"".b
      while (chunk = file.read(READ_BYTES))
        check_cancelled(cancelled)
        source << chunk
        return if source.bytesize > max_size || chunk.include?("\0")
      end
      source.force_encoding(Encoding::UTF_8)
      source if source.valid_encoding?
    end
  rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR, Errno::ELOOP
    nil
  end

  def self.run
    STDIN.binmode
    STDOUT.binmode
    root, paths, expression, max_size, limit, timeout = read_frame(STDIN)
    expression = Regexp.new(expression.source, expression.options, timeout: timeout)
    scan(root, paths, expression, max_size, limit) { |message| write_frame(STDOUT, message) }
    write_frame(STDOUT, [:done])
  rescue StandardError => error
    write_frame(STDOUT, [:error, "#{error.class}: #{error.message}".byteslice(0, 4096)])
    write_frame(STDOUT, [:done])
  end
end

require_relative "search_worker/cancelled"
Canopus::Project.send(:private_constant, :SearchWorker)
