# frozen_string_literal: true

require "set"
require "zaniah/ui"

module Canopus
  module Debug
    class Panel
      ITEM_LIMIT = 1_000
      WATCH_LIMIT = 100
      TEXT_LIMIT = 4_096
      DEPTH_LIMIT = 32
      ROOT_STACK = [:debug, :stack].freeze
      ROOT_VARIABLES = [:debug, :variables].freeze
      ROOT_WATCHES = [:debug, :watches].freeze
      ROOT_BREAKPOINTS = [:debug, :breakpoints].freeze
      ROOTS = [ROOT_STACK, ROOT_VARIABLES, ROOT_WATCHES, ROOT_BREAKPOINTS].freeze

      attr_reader :tree, :watches, :expanded_paths, :selected_frame

      def initialize(breakpoints:, post:, select_frame:, select_breakpoint:, report:, request_frame:)
        callbacks = [post, select_frame, select_breakpoint, report, request_frame]
        raise ArgumentError, "debug panel callbacks must be callable" unless callbacks.all? { |item| item.respond_to?(:call) }

        @breakpoints = breakpoints
        @post, @select_frame, @select_breakpoint = post, select_frame, select_breakpoint
        @report, @request_frame = report, request_frame
        @generation = 0
        @pending = Set.new
        @watches = [].freeze
        @watch_tokens = {}
        @expanded_paths = Set.new
        @expanded_roots = ROOTS.to_set
        @stack_frames, @watch_results = [], {}
        @tree = Zaniah::UI::TreeView.new(nodes, height: 600)
          .on_select { |value, _event, _context| select(value) }
          .on_toggle { |id, open| remember_expansion(id, open) }
        restore_expansions
      end

      def stopped(session, frame)
        reset_requests
        @session, @selected_frame = session, frame
        @stack_frames = [frame].freeze
        @watch_results = @watches.to_h { |expression| [expression, :loading] }
        @tree.replace(nodes)
        restore_expansions
        request_stack
        evaluate_watches
        @request_frame.call
        self
      end

      def continued(session)
        return false unless @session.equal?(session)

        reset_requests
        @session = @selected_frame = nil
        @stack_frames = [].freeze
        @watch_results = {}
        @tree.replace(nodes)
        restore_expansions
        @request_frame.call
        true
      end

      def clear
        reset_requests
        @session = @selected_frame = nil
        @stack_frames = [].freeze
        @watch_results = {}
        @tree.replace(nodes)
        restore_expansions
        @request_frame.call
        nil
      end

      def refresh_breakpoints
        @tree.replace_children(ROOT_BREAKPOINTS, breakpoint_nodes)
        @request_frame.call
        nil
      end

      def add_watch(expression)
        expression = watch_expression(expression)
        return false if @watches.include?(expression)
        raise Error, "too many watch expressions" if @watches.length >= WATCH_LIMIT

        @watches = [*@watches, expression].freeze
        token = @watch_tokens[expression] = Object.new.freeze
        @watch_results[expression] = @session && @selected_frame ? :loading : nil
        @tree.replace_children(ROOT_WATCHES, watch_nodes)
        evaluate_watch(expression, token) if @session && @selected_frame
        @request_frame.call
        true
      end

      def remove_watch(expression)
        replacement = @watches.reject { |item| item == expression }
        return false if replacement.length == @watches.length

        @watches = replacement.freeze
        @watch_tokens.delete(expression)
        @watch_results.delete(expression)
        @expanded_paths.delete_if { |path| path.first == :watch && path.dig(1, 0) == expression }
        @tree.replace_children(ROOT_WATCHES, watch_nodes)
        @request_frame.call
        true
      end

      private

      def nodes
        [root_node(ROOT_STACK, "Call Stack", ->(_value) { stack_nodes }),
         root_node(ROOT_VARIABLES, "Variables", ->(_value) { load_scopes }),
         root_node(ROOT_WATCHES, "Watch", ->(_value) { watch_nodes }),
         root_node(ROOT_BREAKPOINTS, "Breakpoints", ->(_value) { breakpoint_nodes })].freeze
      end

      def root_node(id, label, loader) = {id: id, label: label, value: nil, children: loader}.freeze

      def stack_nodes
        return [status_node(:stack, "Not stopped")] if @stack_frames.empty?

        @stack_frames.each_with_index.map do |frame, index|
          path = frame.source && (frame.source["path"] || frame.source[:path])
          label = path ? text(frame.name, " · ", display_basename(path), ":", frame.line) : text(frame.name)
          {id: [:debug_frame, index].freeze, label: label,
           value: {kind: :frame, generation: @generation, frame: frame}.freeze}.freeze
        end.freeze
      end

      def breakpoint_nodes
        entries = @breakpoints.entries.first(ITEM_LIMIT)
        return [status_node(:breakpoints, "No breakpoints")] if entries.empty?

        entries.map do |entry|
          state = entry.enabled ? "" : " (disabled)"
          {id: [:debug_breakpoint, entry.path, entry.line].freeze,
           label: text(entry.path, ":", entry.line, state),
           value: {kind: :breakpoint, entry: entry}.freeze}.freeze
        end.freeze
      end

      def watch_nodes
        return [status_node(:watches, "No watch expressions")] if @watches.empty?

        @watches.map do |expression|
          result = @watch_results[expression]
          label = case result
          when :loading then text(expression, " = …")
          when Hash then text(expression, " = ", result.fetch(:label))
          else text(expression, " = Not available")
          end
          path = [expression_component(expression)].freeze
          node = {id: watch_variable_id(path), label: label,
            value: {kind: :watch, expression: expression}.freeze}
          if result.is_a?(Hash) && result[:expandable]
            id = watch_variable_id(path)
            node[:children] = watch_variables_loader(expression, path, id, @watch_tokens.fetch(expression))
          end
          node.freeze
        end.freeze
      end

      def request_stack
        generation = @generation
        await(@session.stack_frames(levels: 100), generation) do |frames, error|
          if error
            @tree.replace_children(ROOT_STACK, [status_node(:stack_error, "Unavailable")])
            @report.call(text("Cannot load call stack: ", error.message))
          else
            frames = frames.first(ITEM_LIMIT)
            @stack_frames = (frames.empty? ? [@selected_frame] : frames).freeze
            @tree.replace_children(ROOT_STACK, stack_nodes)
          end
        end
      rescue StandardError => error
        @report.call(text("Cannot load call stack: ", error.message))
      end

      def load_scopes
        return [status_node(:variables, "Not stopped")] unless active?

        generation, session, frame = @generation, @session, @selected_frame
        await(session.scopes(frame.id), generation) do |scopes, error|
          if error
            replace_unavailable(ROOT_VARIABLES, error)
          else
            @tree.replace_children(ROOT_VARIABLES, scope_nodes(scopes))
            restore_expansions
          end
        end
        [status_node(:variables_loading, "Loading…")]
      rescue StandardError => error
        unavailable(error)
      end

      def scope_nodes(scopes)
        occurrences = Hash.new(0)
        values = scopes.first(ITEM_LIMIT).each_with_index.filter_map do |scope, index|
          component = path_component(scope.name, occurrences)
          next oversized_node(:scope, index, scope.name) unless component

          path = [component].freeze
          node = {id: variable_id(path), label: text(scope.name), value: {kind: :scope}.freeze}
          node[:children] = variables_loader(path, variable_id(path)) unless scope.variables_reference.zero?
          node.freeze
        end
        values.empty? ? [status_node(:variables_empty, "No variables")] : values.freeze
      end

      def load_variables(path, node_id)
        return [status_node([:stale, node_id], "Not stopped")] unless active?
        return [status_node([:depth, node_id], "Maximum depth reached")] if path.length >= DEPTH_LIMIT

        generation = @generation
        resolve_reference(path, generation) do |reference, error|
          if error
            replace_unavailable(node_id, error)
          else
            await(@session.variables(reference), generation) do |variables, request_error|
              if request_error
                replace_unavailable(node_id, request_error)
              else
                @tree.replace_children(node_id, variable_nodes(variables, path, :variables))
                restore_expansions
              end
            end
          end
        end
        [status_node([:loading, node_id], "Loading…")]
      rescue StandardError => error
        unavailable(error)
      end

      def load_watch_variables(expression, path, node_id, token)
        return [status_node([:stale, node_id], "Not stopped")] unless active? && watch_current?(expression, token)
        return [status_node([:depth, node_id], "Maximum depth reached")] if path.length >= DEPTH_LIMIT

        generation = @generation
        await(@session.evaluate(expression, frame_id: @selected_frame.id), generation) do |variable, error|
          next unless watch_current?(expression, token)

          if error
            replace_unavailable(node_id, error)
          else
            traverse_reference(variable.variables_reference, path.drop(1), generation) do |reference, resolve_error|
              next unless watch_current?(expression, token)

              if resolve_error
                replace_unavailable(node_id, resolve_error)
              else
                await(@session.variables(reference), generation) do |variables, request_error|
                  next unless watch_current?(expression, token)

                  if request_error
                    replace_unavailable(node_id, request_error)
                  else
                    @tree.replace_children(node_id, variable_nodes(variables, path, :watch))
                    restore_expansions
                  end
                end
              end
            end
          end
        end
        [status_node([:loading, node_id], "Loading…")]
      rescue StandardError => error
        unavailable(error)
      end

      def variable_nodes(variables, parent, kind)
        occurrences = Hash.new(0)
        values = variables.first(ITEM_LIMIT).each_with_index.filter_map do |variable, index|
          component = path_component(variable.name, occurrences)
          next oversized_node(:variable, [parent, index], variable.name) unless component

          path = [*parent, component].freeze
          id = kind == :watch ? watch_variable_id(path) : variable_id(path)
          label = text(variable.name, " = ", variable.value, variable.type && " · ", variable.type)
          node = {id: id, label: label, value: {kind: :variable}.freeze}
          unless variable.variables_reference.zero?
            node[:children] = if kind == :watch
              expression = parent.first.first
              watch_variables_loader(expression, path, id, @watch_tokens.fetch(expression))
            else
              variables_loader(path, id)
            end
          end
          node.freeze
        end
        values.empty? ? [status_node([:empty, parent], "No variables")] : values.freeze
      end

      def resolve_reference(path, generation, &done)
        session, frame = @session, @selected_frame
        await(session.scopes(frame.id), generation) do |scopes, error|
          if error
            done.call(nil, error)
          else
            scope = occurrence(scopes, path.first)
            if !scope || scope.variables_reference.zero?
              done.call(nil, Error.new("variable path is no longer available"))
            else
              traverse_reference(scope.variables_reference, path.drop(1), generation, &done)
            end
          end
        end
      end

      def traverse_reference(reference, path, generation, &done)
        return done.call(reference, nil) if path.empty?
        return done.call(nil, Error.new("variable path is no longer available")) if reference.zero?

        await(@session.variables(reference), generation) do |variables, error|
          if error
            done.call(nil, error)
          else
            variable = occurrence(variables, path.first)
            variable ? traverse_reference(variable.variables_reference, path.drop(1), generation, &done) :
              done.call(nil, Error.new("variable path is no longer available"))
          end
        end
      end

      def evaluate_watches
        @watches.each { |expression| evaluate_watch(expression, @watch_tokens.fetch(expression)) }
      end

      def evaluate_watch(expression, token)
        generation, session, frame = @generation, @session, @selected_frame
        await(session.evaluate(expression, frame_id: frame.id), generation) do |variable, error|
          next unless watch_current?(expression, token)

          @watch_results[expression] = if error
            {label: text("Unavailable: ", error.message), expandable: false}.freeze
          else
            {label: text(variable.value, variable.type && " · ", variable.type),
             expandable: !variable.variables_reference.zero?}.freeze
          end
          @tree.replace_children(ROOT_WATCHES, watch_nodes)
          restore_expansions
          @request_frame.call
        end
      rescue StandardError => error
        return unless watch_current?(expression, token)

        @watch_results[expression] = {label: text("Unavailable: ", error.message), expandable: false}.freeze
        @tree.replace_children(ROOT_WATCHES, watch_nodes)
      end

      def await(future, generation, &accept)
        @pending.add(future)
        future.on_complete do |value, error|
          @post.call do
            @pending.delete(future)
            accept.call(value, error) if generation == @generation && active?
          end
        end
        future
      end

      def reset_requests
        @generation += 1
        pending, @pending = @pending, Set.new
        pending.each(&:cancel)
      end

      def active? = !!(@session && @selected_frame)

      def select(value)
        return false unless value.is_a?(Hash)

        case value[:kind]
        when :frame
          return false unless value[:generation] == @generation && @session

          frame = value.fetch(:frame)
          return true if @selected_frame == frame

          reset_requests
          @selected_frame = frame
          @tree.replace_children(ROOT_STACK, stack_nodes)
          @select_frame.call(@session, @selected_frame)
          @watch_results = @watches.to_h { |expression| [expression, :loading] }
          @tree.invalidate(ROOT_VARIABLES)
          restore_expansions
          @tree.replace_children(ROOT_WATCHES, watch_nodes)
          evaluate_watches
          true
        when :breakpoint
          @select_breakpoint.call(value.fetch(:entry))
        else false
        end
      end

      def remember_expansion(id, open)
        if ROOTS.include?(id)
          open ? @expanded_roots.add(id) : @expanded_roots.delete(id)
        elsif id.is_a?(Array) && id.first == :debug_variable
          remember_path([:variables, *id.drop(1)].freeze, open)
        elsif id.is_a?(Array) && id.first == :debug_watch_variable
          remember_path([:watch, *id.drop(1)].freeze, open)
        end
      end

      def remember_path(path, open)
        open ? @expanded_paths.add(path) : @expanded_paths.delete(path)
      end

      def restore_expansions
        @expanded_roots.each { |id| @tree.expand(id) }
        @expanded_paths.sort_by(&:length).each do |path|
          id = path.first == :variables ? variable_id(path.drop(1)) : watch_variable_id(path.drop(1))
          @tree.expand(id)
        end
      end

      def replace_unavailable(node_id, error)
        @tree.replace_children(node_id, [status_node([:error, node_id], "Unavailable")])
        @report.call(text("Cannot load variables: ", error.message))
      end

      def unavailable(error)
        @report.call(text("Cannot load variables: ", error.message))
        [status_node([:error, error.object_id], "Unavailable")]
      end

      def path_component(name, occurrences)
        return unless name.bytesize <= TEXT_LIMIT

        index = occurrences[name]
        occurrences[name] += 1
        [name.dup.freeze, index].freeze
      end

      def expression_component(expression) = [expression, 0].freeze

      def occurrence(values, component)
        name, index = component
        values.select { |value| value.name == name }[index]
      end

      def variable_id(path) = [:debug_variable, *path].freeze
      def watch_variable_id(path) = [:debug_watch_variable, *path].freeze

      def variables_loader(path, node_id) = ->(_value) { load_variables(path, node_id) }

      def watch_variables_loader(expression, path, node_id, token)
        ->(_value) { load_watch_variables(expression, path, node_id, token) }
      end

      def watch_current?(expression, token) = @watch_tokens[expression].equal?(token)

      def oversized_node(kind, index, name)
        {id: [:debug_oversized, kind, index].freeze, label: text(name), value: nil}.freeze
      end

      def status_node(id, label)
        {id: [:debug_status, id].freeze, label: label, value: nil}.freeze
      end

      def watch_expression(value)
        valid = value.is_a?(String) && value.encoding == Encoding::UTF_8 && value.valid_encoding? &&
          value.bytesize.between?(1, TEXT_LIMIT) && !value.include?("\0") && !value.strip.empty?
        raise ArgumentError, "invalid watch expression" unless valid

        value.dup.freeze
      end

      def display_basename(value)
        path = bounded_text(value).delete("\0")
        path.empty? ? "" : File.basename(path)
      end

      def bounded_text(value)
        value.to_s.byteslice(0, TEXT_LIMIT).to_s.dup.force_encoding(Encoding::UTF_8).scrub("")
      end

      def text(*values)
        value = values.compact.map { |item| bounded_text(item) }.join.gsub(/\s+/, " ").strip
        value.length > 200 ? value.each_char.first(199).join + "…" : value
      end
    end
  end
end
