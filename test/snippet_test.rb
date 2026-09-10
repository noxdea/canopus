# frozen_string_literal: true

require_relative "test_helper"

class SnippetTest < Minitest::Test
  def expand(source, variables = {}) = Canopus::Snippet.new(source, variables: variables)

  def test_variables_defaults_unknown_names_and_unused_nested_defaults
    source = '${KNOWN:${1:unused}} ${EMPTY:default} ${MISSING:default} $UNKNOWN $TM_FILENAME'
    snippet = expand(source, "KNOWN" => "chosen", "EMPTY" => "", "MISSING" => nil)
    assert_equal "chosen  default UNKNOWN ", snippet.text
    assert_equal [2], snippet.tabstops.keys
    assert_equal ["UNKNOWN"], snippet.tabstops[2].map { |range| snippet.text.byteslice(range) }
    assert_equal "main.rb", expand('${TM_FILENAME:fallback}', "TM_FILENAME" => "main.rb").text
    assert_equal "fallback", expand('${TM_FILENAME:fallback}').text
    assert_equal "default", expand('${UNKNOWN:default}').text
  end

  def test_forward_references_and_nested_mirrors_use_first_default
    snippet = expand('$2 ${1:hi ${2:日本}} $1 ${2:other} $0')
    assert_equal "日本 hi 日本 hi 日本 日本 ", snippet.text
    assert_equal [1, 2, 0], snippet.tabstops.keys
    assert_equal ["日本"] * 4, snippet.tabstops[2].map { |range| snippet.text.byteslice(range) }
    assert_equal ["hi 日本"] * 2, snippet.tabstops[1].map { |range| snippet.text.byteslice(range) }
    assert snippet.text.frozen?
    assert snippet.tabstops.frozen?
    assert snippet.occurrences.all?(&:frozen?)
  end

  def test_only_context_appropriate_escapes_are_removed
    slash = 92.chr
    assert_equal "$x } #{slash}q #{slash}", expand(["#{slash}$x", "#{slash}}", "#{slash}q", slash * 2].join(" ")).text
    snippet = expand('${1|a\,b,c\|d,e\\f,\$x,\}z|}')
    assert_equal "a,b", snippet.text
    assert_equal ["a,b", "c|d", 'e\f', '\$x', '\}z'], snippet.choices[1]
    assert snippet.choices[1].all?(&:frozen?)
    assert_equal ["", "x"], expand('${1|,x|}').choices[1]
  end

  def test_strict_validation_and_bounded_expansion
    ['${', '${!}', '${1', '${1:x', '${1|a,b}', '${VAR|a,b|}', '${1000001}', '${1:${1:x}}', '${1:$2}${2:$1}'].each do |source|
      assert_raises(Canopus::Error, source) { expand(source) }
    end
    assert_raises(Canopus::Error) { expand("\xff".b) }
    assert_raises(Canopus::Error) { expand("x" * (Canopus::Snippet::MAX_SOURCE + 1)) }
    assert_raises(Canopus::Error) { expand('$X', "X" => 4) }
    assert_raises(Canopus::Error) { expand('$X$X', "X" => "x" * (Canopus::Snippet::MAX_OUTPUT / 2 + 1)) }
    assert_raises(Canopus::Error) { expand('${1:' * 34 + 'x' + '}' * 34) }
    assert_raises(Canopus::Error) { expand('$1 ' * (Canopus::Snippet::MAX_NODES + 1)) }
    assert_raises(Canopus::Error) { expand('${' + '1' * 10_000 + '}') }
    assert_equal "ascii", expand("ascii".encode(Encoding::US_ASCII)).text
  end

  def test_variable_transforms_and_placeholder_transform_metadata
    source = '${FILE/(.*)\..+$/${1:/upcase}/} ${1:日本} ${1/(.*)/[$1]/}'
    snippet = expand(source, "FILE" => "main.rb")
    assert_equal "MAIN 日本 日本", snippet.text
    assert_equal ["日本"], snippet.tabstops[1].map { |range| snippet.text.byteslice(range) }
    assert_equal 1, snippet.transforms.length
    occurrence = snippet.transforms.first
    assert_equal [1, "日本", []], [occurrence.index, snippet.text.byteslice(occurrence.range), occurrence.parents]
    assert_equal "[日本]", occurrence.transform.apply("日本")
  end
end

class EditorSnippetTest < Minitest::Test
  def setup
    @editor = Canopus::Editor.new
    @editor.auto_pairs = false
  end

  def teardown = @editor.dispose
  def selected = @editor.selections.map { |selection| @editor.buffer.rope.byteslice(selection.range).to_s }

  def test_independent_transforms_apply_on_tab_and_can_be_revisited
    @editor.insert_snippet('${1:first} ${1/(.*)/${1:/upcase}/} ${1/(.*)/[$1]/} ${2:last}$0')
    @editor.insert_text("日本x")
    assert_equal "日本x first first last", @editor.buffer.text
    assert @editor.next_snippet
    assert_equal "日本x 日本X [日本x] last", @editor.buffer.text
    assert_equal ["last"], selected
    assert @editor.previous_snippet
    assert_equal ["日本x"], selected
    @editor.insert_text("second")
    assert @editor.next_snippet
    assert_equal "second SECOND [second] last", @editor.buffer.text
    assert @editor.next_snippet
    refute @editor.snippet_active?
    refute @editor.previous_snippet
    assert_empty @editor.buffer.instance_variable_get(:@anchors)
  end

  def test_choices_validate_and_update_all_mirrors
    @editor.insert_snippet('${1|yes,no\,thanks,maybe\|later|} $1 ${2:next}')
    assert_equal ["yes", "no,thanks", "maybe|later"], @editor.snippet_choices
    refute @editor.choose_snippet(-1)
    refute @editor.choose_snippet(8)
    refute @editor.choose_snippet("not a choice")
    assert @editor.choose_snippet(1)
    assert_equal "no,thanks no,thanks next", @editor.buffer.text
    assert @editor.choose_snippet("maybe|later")
    assert_equal "maybe|later maybe|later next", @editor.buffer.text
    @editor.next_snippet
    assert_nil @editor.snippet_choices
    @editor.previous_snippet
    assert_equal ["maybe|later"] * 2, selected
  end

  def test_adjacent_empty_fields_do_not_absorb_previous_field_text
    @editor.insert_snippet('$1$2$0')
    @editor.insert_text("日本")
    @editor.next_snippet
    assert_equal [""], selected
    assert_equal 6, @editor.primary.head
    @editor.insert_text("語")
    @editor.previous_snippet
    assert_equal ["日本"], selected
    @editor.next_snippet
    assert_equal ["語"], selected
    @editor.next_snippet
    assert_equal 9, @editor.primary.head
  end

  def test_adjacent_and_coincident_mirrors_stay_distinct_through_typing_and_deletion
    @editor.insert_snippet('${1:a}$1$0')
    assert_equal ["a", "a"], selected
    @editor.insert_text("日本")
    assert_equal "日本日本", @editor.buffer.text
    @editor.previous_snippet
    @editor.choose_snippet(0) # Not a choice; must leave the two cursors intact.
    @editor.delete_backward
    assert_equal "日日", @editor.buffer.text
    @editor.delete_backward
    assert_equal "", @editor.buffer.text
    assert_equal [0, 0], @editor.selections.map(&:head)
    @editor.insert_text("x")
    assert_equal "xx", @editor.buffer.text
    @editor.next_snippet
    assert_equal 2, @editor.primary.head
    @editor.select(0)
    @editor.select(0, add: true)
    assert_equal 1, @editor.selections.length
    @editor.insert_snippet('$1$1$0')
    assert_equal ["", ""], selected
    @editor.insert_text("z")
    assert_equal "zzxx", @editor.buffer.text
    @editor.next_snippet
    assert_equal 2, @editor.primary.head
  end

  def test_adjacent_transformed_empty_mirrors_get_independent_ranges
    @editor.insert_snippet('${1:x}${1/.*/A/}${1/.*/BB/}${2:last}')
    @editor.insert_text("")
    @editor.next_snippet
    assert_equal "ABBlast", @editor.buffer.text
    assert_equal ["last"], selected
    @editor.previous_snippet
    @editor.insert_text("q")
    @editor.next_snippet
    assert_equal "qABBlast", @editor.buffer.text
  end

  def test_all_transforms_are_preflighted_before_any_edit
    @editor.insert_snippet('${1:x} ${1/.*/changed/} ${1/a{10000}b/failed/} ${2:next}')
    @editor.insert_text("a" * 1_000_000 + "!")
    before = @editor.buffer.text
    selections = @editor.selections
    assert_raises(Canopus::Error) { @editor.next_snippet }
    assert_equal before, @editor.buffer.text
    assert_equal selections, @editor.selections
    assert @editor.snippet_active?
  end

  def test_mirror_and_final_anchor_matrix_for_adjacent_utf8_edits
    [1, 2, 5].product(["", " ", "日本"], ["a", "語", "😀"]).each do |count, separator, value|
      editor = Canopus::Editor.new
      editor.auto_pairs = false
      template = (["${1:x}"] + ["$1"] * count).join(separator) + ':${2:next}$0'
      editor.insert_snippet(template)
      editor.insert_text(value)
      assert_equal ([value] * (count + 1)).join(separator) + ":next", editor.buffer.text
      editor.insert_text("z")
      assert_equal ([value + "z"] * (count + 1)).join(separator) + ":next", editor.buffer.text
      editor.delete_backward
      editor.next_snippet
      assert_equal "next", editor.buffer.rope.byteslice(editor.primary.range).to_s
      editor.previous_snippet
      assert_equal [value] * (count + 1), editor.selections.map { |selection| editor.buffer.rope.byteslice(selection.range).to_s }
      editor.insert_text("")
      editor.insert_text(value)
      editor.next_snippet
      editor.next_snippet
      assert_equal editor.buffer.rope.bytesize, editor.primary.head
      assert_empty editor.buffer.instance_variable_get(:@anchors)
      editor.dispose
    end
  end

  def test_empty_source_after_transformed_mirror_stays_after_it
    @editor.insert_snippet('${1/.*/A/}$1${2:last}')
    @editor.next_snippet
    assert_equal "Alast", @editor.buffer.text
    @editor.previous_snippet
    assert_equal 1, @editor.primary.head
    assert_equal [""], selected
    @editor.insert_text("x")
    @editor.next_snippet
    assert_equal "Axlast", @editor.buffer.text
  end

  def test_duplicate_final_positions_are_normalized_when_session_ends
    @editor.insert_snippet('$1$0$0')
    @editor.insert_text("x")
    @editor.next_snippet
    assert_equal [1], @editor.selections.map(&:head)
    @editor.insert_text("y")
    assert_equal "xy", @editor.buffer.text
  end

  def test_nested_fields_removed_only_when_replaced_and_ancestors_track_children
    @editor.insert_snippet('${1:hello ${2:world}} ${3:end}')
    @editor.next_snippet
    assert_equal ["world"], selected
    @editor.insert_text("日本")
    @editor.previous_snippet
    assert_equal ["hello 日本"], selected
    @editor.insert_text("replacement")
    @editor.next_snippet
    assert_equal ["end"], selected
    @editor.previous_snippet
    assert_equal ["replacement"], selected
  end

  def test_equal_nested_ranges_are_distinguished_from_adjacent_fields
    @editor.insert_snippet('${1:${2:x}}$3$0')
    @editor.insert_text("y")
    @editor.next_snippet
    assert_equal [""], selected
    assert_equal 1, @editor.primary.head
    @editor.insert_text("z")
    @editor.next_snippet
    assert_equal "yz", @editor.buffer.text
    assert_equal 2, @editor.primary.head
  end

  def test_multi_cursor_expansion_and_transform_source_are_per_instance
    @editor.buffer.edit([[0...0, "a\nb"]])
    @editor.select(0, 1)
    @editor.select(2, 3, add: true)
    @editor.insert_snippet('${1:$TM_SELECTED_TEXT}$CURSOR_INDEX:${1/(.*)/${1:/upcase}/}$0')
    assert_equal "a0:a\nb1:b", @editor.buffer.text
    assert_equal ["a", "b"], selected
    @editor.next_snippet
    assert_equal "a0:A\nb1:B", @editor.buffer.text
    assert_equal [4, 9], @editor.selections.map(&:head)
    refute @editor.snippet_active?
  end

  def test_implicit_final_caret_unknown_placeholder_and_plain_insert
    @editor.insert_snippet('$UNKNOWN!')
    assert_equal ["UNKNOWN"], selected
    @editor.insert_text("value")
    @editor.next_snippet
    assert_equal "value!", @editor.buffer.text
    assert_equal 6, @editor.primary.head
    refute @editor.snippet_active?
    @editor.insert_snippet("plain")
    refute @editor.snippet_active?
    assert_equal 11, @editor.primary.head
  end

  def test_invalid_insertion_preserves_existing_text_selection_and_session
    @editor.insert_snippet('${1:before} ${2:after}')
    before = @editor.selections
    assert_raises(Canopus::Error) { @editor.insert_snippet('${1:bad') }
    assert_equal "before after", @editor.buffer.text
    assert_equal before, @editor.selections
    assert @editor.snippet_active?
    @editor.next_snippet
    assert_equal ["after"], selected
  end

  def test_undo_redo_and_dispose_release_anchors
    @editor.insert_snippet('${1:a} ${2:b}')
    @editor.insert_text("x")
    assert @editor.undo
    refute @editor.snippet_active?
    assert_empty @editor.buffer.instance_variable_get(:@anchors)
    assert @editor.redo
    refute @editor.snippet_active?
    @editor.insert_snippet('${1:a}')
    @editor.dispose
    assert_empty @editor.buffer.instance_variable_get(:@anchors)
  end

  def test_external_prefix_edit_keeps_anchored_navigation
    @editor.insert_snippet('prefix ${1:one} ${2:two}')
    @editor.buffer.edit([[0...0, "日本 "]])
    @editor.next_snippet
    assert_equal ["two"], selected
    assert_equal "日本 prefix one two", @editor.buffer.text
  end

  def test_transform_only_field_can_be_edited_and_left
    @editor.insert_snippet('${1/(.*)/${1:/upcase}/}$0')
    @editor.insert_text("hello")
    @editor.next_snippet
    assert_equal "HELLO", @editor.buffer.text
    assert_equal 5, @editor.primary.head
  end

  def test_builtin_variables_are_contextual_and_explicit_values_win
    root = File.expand_path("project", Dir.tmpdir)
    path = File.join(root, "lib", "main.rb")
    buffer = Canopus::Buffer.new("first\nhello world\n", path: path)
    editor = Canopus::Editor.new(buffer)
    editor.select(8, 11)
    now = Time.new(2026, 9, 9, 12, 34, 56.789, "+09:00")
    variables = editor.snippet_variables(workspace_root: root, clipboard: "clip", now: now)
    expected = {"TM_SELECTED_TEXT" => "llo", "TM_CURRENT_LINE" => "hello world", "TM_CURRENT_WORD" => "hello",
      "TM_LINE_INDEX" => "1", "TM_LINE_NUMBER" => "2", "TM_FILENAME" => "main.rb", "TM_FILENAME_BASE" => "main",
      "TM_DIRECTORY" => File.dirname(path), "TM_FILEPATH" => path, "RELATIVE_FILEPATH" => "lib/main.rb",
      "WORKSPACE_NAME" => "project", "WORKSPACE_FOLDER" => root, "CLIPBOARD" => "clip", "CURSOR_INDEX" => "0", "CURSOR_NUMBER" => "1",
      "CURRENT_YEAR" => "2026", "CURRENT_YEAR_SHORT" => "26", "CURRENT_MONTH" => "09", "CURRENT_MONTH_NAME" => "September",
      "CURRENT_DATE" => "09", "CURRENT_DAY_NAME" => "Wednesday", "CURRENT_HOUR" => "12", "CURRENT_MINUTE" => "34",
      "CURRENT_SECOND" => "56", "CURRENT_TIMEZONE_OFFSET" => "+09:00", "LINE_COMMENT" => "#"}
    expected.each { |key, value| assert_equal value, variables[key], key }
    assert_match(/\A\d{6}\z/, variables["RANDOM"])
    assert_match(/\A[0-9a-f]{6}\z/, variables["RANDOM_HEX"])
    assert_match(/\A[0-9a-f-]{14}4[0-9a-f-]{21}\z/, variables["UUID"])
    editor.insert_snippet('${TM_FILENAME:unknown}', variables: {"TM_FILENAME" => "override"})
    assert_equal "first\nheoverride world\n", buffer.text
  ensure
    editor&.dispose
  end
end
