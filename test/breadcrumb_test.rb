# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class BreadcrumbTest < Minitest::Test
  class Client
    def initialize = @running = true
    def running? = @running
    def stop = @running = false
  end

  class NoScanArray < Array
    attr_reader :reads
    def initialize(*) = (super; @reads = 0)
    def each(*) = raise("paint scanned every symbol")
    def select(*) = raise("paint scanned every symbol")
    def [](*) = (@reads += 1; raise("paint scanned every symbol") if @reads > 100; super)
  end

  def setup
    @root = Dir.mktmpdir("canopus-breadcrumb-")
    FileUtils.mkdir_p(File.join(@root, "日本語"))
    @path = File.join(@root, "日本語", "対象.rb")
    @other = File.join(@root, "日本語", "兄弟.rb")
    File.write(@path, <<~RUBY)
      module 外側
        class 内側
          def 同名
            puts :first
          end

          def 同名
            puts :second
          end
        end
      end
      #{(0...70).map { |index| "value_#{index}\n" }.join}
    RUBY
    File.write(@other, "puts :sibling\n")
    FileUtils.mkdir_p(File.join(@root, "別"))
    File.write(File.join(@root, "別", "除外.rb"), "puts :excluded\n")
    @settings = Canopus::Settings.new("bracket_colorization" => false,
      "indent_guides" => {"enabled" => false, "active" => false})
    @workspace = Canopus::Workspace.new(root: @root, settings: @settings)
    @editor = @workspace.open(@path)
    install_symbols(@editor)
  end

  def teardown
    @workspace.close
    @window&.on_close { true }
    @window&.close
    FileUtils.remove_entry(@root)
  end

  def test_settings_and_semantic_context_use_byte_caret_and_language_override
    assert_equal({"enabled" => true}, @settings["breadcrumbs"])
    assert_equal "boolean", Canopus::Settings.schema.dig("properties", "breadcrumbs", "properties", "enabled", "type")
    assert_raises(Canopus::Error) { Canopus::Settings.new("breadcrumbs" => {"enabled" => "yes"}) }

    @editor.select(@editor.buffer.rope.line_start(3))
    context = @workspace.breadcrumb_context(@editor)
    assert_equal ["日本語/対象.rb", "内側", "同名"], context[:items].map { |item| item[:label] }
    assert_equal [:path, :symbol, :symbol], context[:items].map { |item| item[:kind] }

    settings = Canopus::Settings.new("breadcrumbs" => {"enabled" => false},
      "languages" => {"ruby" => {"breadcrumbs" => {"enabled" => true}}})
    workspace = Canopus::Workspace.new(root: @root, settings: settings)
    current = workspace.open(@path)
    assert workspace.breadcrumb_context(current)
    disabled = Canopus::Workspace.new(root: @root,
      settings: Canopus::Settings.new("breadcrumbs" => {"enabled" => false}))
    assert_nil disabled.breadcrumb_context(disabled.open(@path))
  ensure
    workspace&.close
    disabled&.close
  end

  def test_symbols_are_requested_when_sticky_scroll_is_disabled
    settings = Canopus::Settings.new("sticky_scroll" => {"enabled" => false})
    workspace = Canopus::Workspace.new(root: @root, settings: settings)
    current = workspace.open(@path)
    window = Zaniah::Platform.open_window(backend: :headless, width: 420, height: 220)
    controller = Canopus::Controller.new(workspace, window)
    requested = false

    workspace.stub(:request_sticky_symbols, ->(editor) { requested = editor.equal?(current) }) do
      controller.poll_language_documents
    end
    assert requested
  ensure
    window&.on_close { true }
    window&.close
    workspace&.close
  end

  def test_symbol_palette_keeps_filtered_indices_unique_and_returns_to_source_split
    @editor.select(@editor.buffer.rope.line_start(3))
    first_pane = @workspace.active_pane
    context = @workspace.breadcrumb_context(@editor)
    item = context[:items].last
    @workspace.split(:horizontal)
    second_pane = @workspace.active_pane

    assert @workspace.show_breadcrumb_menu(first_pane, @editor, item, context)
    labels = @workspace.palette[:matches]
    assert_equal 2, labels.length
    assert_equal 2, labels.uniq.length
    assert labels.all? { |label| label.include?("同名 — ") }

    wanted = labels.last
    @workspace.palette[:query] = wanted
    @workspace.update_palette
    assert_equal [wanted], @workspace.palette[:matches]
    @workspace.focus(second_pane)
    @workspace.palette_accept

    assert_same first_pane, @workspace.active_pane
    assert_same @editor, @workspace.editor
    assert_equal 6, @editor.buffer.rope.point_at(@editor.primary.head).row
  end

  def test_path_palette_is_directory_scoped_and_rejects_edit_save_as_client_and_close_staleness
    context = @workspace.breadcrumb_context(@editor)
    path_item = context[:items].first
    assert @workspace.show_breadcrumb_menu(@workspace.active_pane, @editor, path_item, context)
    assert_equal ["日本語/兄弟.rb", "日本語/対象.rb"], @workspace.palette[:items].sort
    @workspace.palette[:query] = "兄弟"
    @workspace.update_palette
    @workspace.palette_accept
    assert_equal File.realpath(@other), @workspace.editor.buffer.path

    @workspace.activate_tab(@workspace.active_pane, @editor)
    context = @workspace.breadcrumb_context(@editor)
    assert @workspace.show_breadcrumb_menu(@workspace.active_pane, @editor, context[:items].last, context)
    pane = @workspace.active_pane
    sibling_editor = pane.editors.find { |current| !current.equal?(@editor) }
    @workspace.activate_tab(pane, sibling_editor)
    refute @workspace.palette_accept

    @workspace.activate_tab(pane, @editor)
    context = @workspace.breadcrumb_context(@editor)
    assert @workspace.show_breadcrumb_menu(pane, @editor, context[:items].last, context)
    @editor.insert_text("# changed\n", auto_indent: false)
    refute @workspace.palette_accept

    install_symbols(@editor)
    client = Client.new
    @workspace.clients["ruby"] = client
    @workspace.instance_variable_set(:@opened_lsp_documents, {[client, @editor.buffer] => true})
    context = @workspace.breadcrumb_context(@editor)
    assert @workspace.show_breadcrumb_menu(@workspace.active_pane, @editor, context[:items].last, context)
    @workspace.clients["ruby"] = Client.new
    refute @workspace.palette_accept

    @workspace.clients.delete("ruby")
    context = @workspace.breadcrumb_context(@editor)
    assert @workspace.show_breadcrumb_menu(@workspace.active_pane, @editor, context[:items].last, context)
    @workspace.save_buffer(@editor.buffer, path: File.join(@root, "日本語", "変更後.rb"))
    refute @workspace.palette_accept

    install_symbols(@editor)
    context = @workspace.breadcrumb_context(@editor)
    assert @workspace.show_breadcrumb_menu(@workspace.active_pane, @editor, context[:items].last, context)
    @workspace.close_editor(@editor, discard: true)
    refute @workspace.palette_accept
  end

  def test_layout_click_wheel_clipping_resize_and_eof_are_safe
    @editor.select(@editor.buffer.rope.line_start(3))
    @editor.scroll(dy: 3)
    first_pane = @workspace.active_pane
    @workspace.split(:horizontal)
    second_editor = @workspace.editor
    @window = Zaniah::Platform.open_window(backend: :headless, width: 420, height: 240)
    @window.text_system = Zaniah::TextSystem::Renderer.new
    controller = Canopus::Controller.new(@workspace, @window)
    controller.tick

    breadcrumbs = controller.view.regions.select { |_bounds, action| action.first == :breadcrumb && action[2].equal?(@editor) }
    sticky = controller.view.regions.select { |_bounds, action| action.first == :sticky && action[2].equal?(@editor) }
    body = controller.view.editor_bounds.fetch(@editor)
    refute_empty breadcrumbs
    assert_operator breadcrumbs.first.first.bottom, :<=, sticky.first.first.y
    assert_equal sticky.last.first.bottom, body.y
    assert controller.view.accessibility.any? { |entry| entry[:role] == :button && entry[:label].start_with?("Choose siblings") }
    assert @window.text_runs.all? { |run| run[2].valid_encoding? }

    before = @editor.scroll_y
    other = second_editor.scroll_y
    point = Zaniah::Point.new(breadcrumbs.first.first.x + 1, breadcrumbs.first.first.y + 1)
    controller.input(Zaniah::Input::ScrollWheel.new(point, Zaniah::Point.new(0, 20), 8, []))
    assert_operator @editor.scroll_y, :>, before
    assert_equal other, second_editor.scroll_y

    controller.input(Zaniah::Input::MouseDown.new(point, :left, [], 1))
    assert_same first_pane, @workspace.active_pane
    assert_equal :breadcrumbs, @workspace.palette[:kind]

    @workspace.palette = nil
    @window.resize(180, 74)
    controller.tick
    assert_empty controller.view.regions.select { |_bounds, action| action.first == :breadcrumb }
    assert_operator @editor.viewport_rows, :>=, 1

    @editor.select(@editor.buffer.rope.bytesize)
    @window.resize(420, 240)
    controller.tick
    assert controller.view.regions.any? { |_bounds, action| action.first == :breadcrumb && action[2].equal?(@editor) }
  end

  def test_ten_thousand_symbol_paint_uses_index_without_request_parse_or_full_scan
    symbols = 10_000.times.map do |index|
      start = [index * 2, @editor.buffer.rope.bytesize - 1].min
      Canopus::Language::DocumentSymbol.new(index, "symbol_#{index}", 6, start...(start + 1), start...start, 0, nil)
    end.freeze
    indexed = NoScanArray.new(symbols)
    children = {nil => indexed}.freeze
    entry = {buffer: @editor.buffer, version: @editor.buffer.version, client: nil, generation: 50_000,
      symbols: symbols, by_id: symbols.to_h { |symbol| [symbol.id, symbol] }.freeze,
      children: children}.freeze
    @workspace.instance_variable_set(:@sticky_fallback_cache,
      {@editor => [@editor.buffer.version, @editor.language_document, nil, entry]})
    @editor.select(5)
    @window = Zaniah::Platform.open_window(backend: :headless, width: 420, height: 220)
    controller = Canopus::Controller.new(@workspace, @window)

    @workspace.stub(:request_sticky_symbols, ->(*) { raise "paint requested symbols" }) do
      @editor.language_document.stub(:structure_regions, -> { raise "paint parsed structure" }) { controller.tick }
    end
    assert controller.view.regions.any? { |_bounds, action| action.first == :breadcrumb }
    assert_operator indexed.reads, :<, 100
  end

  def test_lsp_struct_is_a_container_and_enum_member_is_not
    rope = @editor.buffer.rope
    method_start = rope.line_start(2)
    symbols = [
      Canopus::Language::DocumentSymbol.new(0, "構造体", 23, 0...rope.bytesize, 0...0, 0, nil),
      Canopus::Language::DocumentSymbol.new(1, "呼出", 6, method_start...rope.line_start(5),
        method_start...method_start, 1, 0)
    ].freeze
    install_symbol_values(symbols)
    @editor.select(rope.line_start(3))
    assert_equal ["日本語/対象.rb", "構造体", "呼出"],
      @workspace.breadcrumb_context(@editor)[:items].map { |item| item[:label] }

    member_start = rope.line_start(1)
    symbols = [
      Canopus::Language::DocumentSymbol.new(0, "列挙", 10, 0...rope.bytesize, 0...0, 0, nil),
      Canopus::Language::DocumentSymbol.new(1, "値", 22, member_start...rope.line_start(2),
        member_start...member_start, 1, 0)
    ].freeze
    install_symbol_values(symbols)
    @editor.select(member_start)
    assert_equal ["日本語/対象.rb", "列挙"],
      @workspace.breadcrumb_context(@editor)[:items].map { |item| item[:label] }
  end

  private

  def install_symbols(current)
    rope = current.buffer.rope
    finish = rope.bytesize
    symbols = [
      Canopus::Language::DocumentSymbol.new(0, "外側", 2, 0...finish, 0...0, 0, nil),
      Canopus::Language::DocumentSymbol.new(1, "内側", 5, rope.line_start(1)...rope.line_start(10),
        rope.line_start(1)...rope.line_start(1), 1, 0),
      Canopus::Language::DocumentSymbol.new(2, "同名", 6, rope.line_start(2)...rope.line_start(5),
        rope.line_start(2)...rope.line_start(2), 2, 1),
      Canopus::Language::DocumentSymbol.new(3, "同名", 6, rope.line_start(6)...rope.line_start(9),
        rope.line_start(6)...rope.line_start(6), 2, 1)
    ].freeze
    install_symbol_values(symbols, current)
    symbols
  end

  def install_symbol_values(symbols, current = @editor)
    entry = @workspace.send(:sticky_cache_entry, current.buffer, current.buffer.version, nil, symbols)
    cache = @workspace.instance_variable_get(:@sticky_fallback_cache) || {}
    cache[current] = [current.buffer.version, current.language_document, nil, entry]
    @workspace.instance_variable_set(:@sticky_fallback_cache, cache)
  end
end
