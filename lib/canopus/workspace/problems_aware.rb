# frozen_string_literal: true

require "zaniah/ui"

module Canopus
  module Workspace::ProblemsAware
    PROBLEM_LABEL_LIMIT = 200
    PROBLEM_FILTER_LIMIT = 4_096

    def problems_tree
      @problems_tree ||= Zaniah::UI::TreeView.new(problem_nodes, height: 320).on_select do |value, _event, _context|
        select_problem(value)
      end
    end

    def filter_problems(severity: nil, source: nil, text: nil)
      severity = Diagnostics::SEVERITIES.fetch(severity, severity) if severity.is_a?(Symbol)
      unless severity.nil? || severity.is_a?(Integer) && severity.between?(1, 4)
        raise ArgumentError, "invalid problem severity"
      end
      unless source.nil? || Diagnostics::SOURCES.include?(source)
        raise ArgumentError, "invalid problem source"
      end
      unless text.nil? || text.is_a?(String) && text.encoding == Encoding::UTF_8 && text.valid_encoding? &&
          text.bytesize <= PROBLEM_FILTER_LIMIT && !text.include?("\0")
        raise ArgumentError, "invalid problem text"
      end

      @problem_filter = {severity: severity, source: source, text: text&.downcase}.freeze
      refresh_problems
      @problem_filter
    end

    def show_problem_filter
      self.palette = {kind: :problem_filter, query: +(@problem_filter_query || ""), index: 0, matches: []}
    end

    private

    def apply_problem_filter(query)
      unless query.is_a?(String) && query.encoding == Encoding::UTF_8 && query.valid_encoding? &&
          query.bytesize <= PROBLEM_FILTER_LIMIT && !query.include?("\0")
        raise ArgumentError, "invalid problem filter"
      end
      severity = source = nil
      text = query.gsub(/(?:\A|\s+)(severity|source):(\S+)/i) do
        key, value = Regexp.last_match(1).downcase, Regexp.last_match(2).downcase
        if key == "severity"
          severity = value == "all" ? nil : Diagnostics::SEVERITIES.find { |name, _| name.to_s == value }&.last
          raise ArgumentError, "invalid problem severity" if value != "all" && !severity
        else
          source = value == "all" ? nil : Diagnostics::SOURCES.find { |name| name.to_s == value }
          raise ArgumentError, "invalid problem source" if value != "all" && !source
        end
        " "
      end.gsub(/\s+/, " ").strip
      @problem_filter_query = query.dup.freeze
      filter_problems(severity: severity, source: source, text: text)
      @panels.show("problems")
    end

    def diagnostics_changed(uri)
      uris = uri.is_a?(Array) ? uri : [uri]
      targets = uris.each_with_object({}) do |value, result|
        Sadr::Protocol.path(value)
        result[value] = true
      end
      @buffers.each_value.uniq.each do |buffer|
        invalidate_diagnostics(buffer) if buffer.path && targets.key?(Sadr::Protocol.uri(buffer.path))
      end
      refresh_problems
    rescue Sadr::Error
      nil
    end

    def refresh_problems
      @problems_tree&.replace(problem_nodes)
      count = @diagnostics.counts.values.sum
      @panels.badge("problems", count.zero? ? nil : count) if @panels&.key?("problems")
      @window&.request_frame
      nil
    end

    def problem_nodes
      filter = @problem_filter || {}
      entries = @diagnostics.all(severity: filter[:severity], source: filter[:source])
      if (text = filter[:text]) && !text.empty?
        entries = entries.select { |entry| entry.diagnostic.fetch("message").downcase.include?(text) }
      end
      entries.group_by(&:uri).map do |uri, problems|
        {id: [:problem_file, uri].freeze, label: problem_path(uri), value: nil,
         children: problems.map do |entry|
           diagnostic = entry.diagnostic
           severity = Diagnostics::SEVERITIES.key(diagnostic.fetch("severity", 1))
           line = diagnostic.dig("range", "start", "line") + 1
           message = diagnostic.fetch("message").gsub(/\s+/, " ").strip
           label = "#{severity} [#{entry.source}] #{line}: #{message}"
           label = label.each_char.first(PROBLEM_LABEL_LIMIT - 1).join + "…" if label.length > PROBLEM_LABEL_LIMIT
           {id: [:problem, entry.source, uri, diagnostic.object_id].freeze,
            label: label.freeze, value: entry}.freeze
         end.freeze}.freeze
      end.freeze
    end

    def problem_path(uri)
      path = Sadr::Protocol.path(uri)
      prefix = @root + File::SEPARATOR
      label = path.start_with?(prefix) ? path.delete_prefix(prefix) : path
      label.length > PROBLEM_LABEL_LIMIT ? label.each_char.first(PROBLEM_LABEL_LIMIT - 1).join + "…" : label
    end

    def select_problem(entry)
      return false unless entry.is_a?(Diagnostics::Entry)

      path = Sadr::Protocol.path(entry.uri)
      raise Error, "Problem target is not a file" unless File.file?(path)
      target = open(path)
      position = Sadr::Protocol.range_value(entry.diagnostic.fetch("range")).start
      offset = Sadr::Protocol.offset(target.buffer.rope, position)
      unless Sadr::Protocol.position(target.buffer.rope, offset) == position
        raise Error, "Problem target position is no longer valid"
      end
      target.select(offset)
      target.reveal_cursor
      true
    rescue Error, KeyError, RangeError, TypeError, SystemCallError, Sadr::Error => error
      @message = "Cannot open problem: #{error.message}"
      false
    end
  end
end
