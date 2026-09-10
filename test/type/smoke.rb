# frozen_string_literal: true
# A standalone contract exercised against a clean installed gem and its runtime dependencies.
require "canopus"
require "tmpdir"
require "canopus/workspace/edit/plan"

def check(value, message)
  raise message unless value
end

Dir.mktmpdir("canopus-public-api-") do |root|
  workspace = Canopus::Workspace.new(root: root, settings: Canopus::Settings.new)
  editor = workspace.new_buffer
  editor.insert_text("日本 😀\nhello")
  check(editor.buffer.text == "日本 😀\nhello", "Unicode edit")
  editor.move(:file_start)
  editor.move(:right)
  check(editor.primary.head == 3, "UTF-8 cursor")
  anchor = editor.buffer.anchor(3)
  editor.select(0)
  editor.insert_text("x")
  check(editor.buffer.resolve(anchor) == 4, "anchor mapping")
  check(editor.undo && editor.buffer.text.start_with?("日本"), "undo")
  editor.buffer.release_anchor(anchor)
  path = File.join(root, "file.txt")
  editor.buffer.save(path)
  check(File.read(path) == editor.buffer.text, "save")
  editor.select_all
  editor.insert_snippet('${1:name} = $1; $0')
  editor.insert_text("value")
  check(editor.buffer.text == "value = value; ", "snippet mirrors")
  editor.clear_snippet
  vim = Canopus::Vim.new(editor)
  vim.feed("0")
  vim.feed("x")
  check(editor.buffer.text.start_with?("alue"), "Vim edit")
  vim.feed("u")
  check(editor.buffer.text.start_with?("value"), "Vim undo")
  vim.dispose
  workspace.split
  check(workspace.panes.first.active.buffer.equal?(workspace.editor.buffer), "shared split buffer")
  session = File.join(root, "session.json")
  workspace.save_session(session)
  workspace.restore_session(session)
  check(workspace.editor.buffer.dirty?, "unsaved session")

  project = Canopus::Project.new(root)
  check(project.files.to_a.include?("file.txt"), "project files enumerator")
  seen = []
  check(project.files { |name| seen << name }.equal?(project) && seen.include?("file.txt"), "project files block")
  check(project.search("日本", workers: 1).first.byte_offset == 0, "project Unicode search")
  rules = Canopus::Project::IgnoreMatcher.new.add("*.tmp\n!keep.tmp\n")
  check(rules.ignored?("skip.tmp") && !rules.ignored?("keep.tmp"), "ignore negation")
  watcher = project.watcher
  File.binwrite(File.join(root, "watch.txt"), "found\n")
  check(watcher.poll.map(&:type) == [:created], "polling watcher")
  watcher.close
  check(project.replace("found", "updated", workers: 1) == {"watch.txt" => 1}, "atomic replacement")

  syntax_buffer = Canopus::Buffer.new("class 日本\nend\n", path: "example.rb")
  syntax = Canopus::Language::Document.new(syntax_buffer)
  begin
    check(syntax.tokens_for(0) == [["Text", "class 日本\n"]], "provisional language tokens")
    syntax.request(first_line: 0, last_line: 2, syntax: true)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    while syntax.pending?
      syntax.poll
      raise "installed syntax worker timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.005
    end
    check(syntax.syntax_ready? && syntax.syntax_complete?, "installed syntax child result")
    check(syntax.outline.map(&:name) == ["日本"], "installed Prism outline")
    check(syntax.tokens_for(0).any? { |token, _| token == "Keyword" }, "installed Rouge tokens")
  ensure
    syntax.dispose
    syntax_buffer.close
  end

  source = Canopus::Buffer.new("alpha\nbeta\n")
  multi = Canopus::MultiBuffer.new(excerpts: [[source, 0...5, "source"]])
  first = multi.excerpts.first.view_start
  multi.begin_undo_group
  multi.edit([[first...(first + 5), "gamma"]])
  multi.end_undo_group
  check(source.text == "gamma\nbeta\n" && multi.dirty?, "editable excerpt")
  check(multi.undo && source.text == "alpha\nbeta\n" && multi.redo, "excerpt undo/redo")
  multi.close
  source.close

  # A complete loose-object fixture needs no Git executable or network.
  git_dir = File.join(root, ".git")
  FileUtils.mkdir_p(File.join(git_dir, "objects"))
  FileUtils.mkdir_p(File.join(git_dir, "refs/heads"))
  object = lambda do |type, data|
    oid = Canopus::Git::ObjectDatabase.hash(type, data)
    directory = File.join(git_dir, "objects", oid[0, 2])
    FileUtils.mkdir_p(directory)
    File.binwrite(File.join(directory, oid[2..]), Zlib::Deflate.deflate("#{type} #{data.bytesize}\0".b + data.b))
    oid
  end
  blob = object.call("blob", "before\n")
  tree = object.call("tree", "100644 tracked.txt\0".b + [blob].pack("H*"))
  commit = object.call("commit", "tree #{tree}\nauthor Test <test@example.invalid> 0 +0000\ncommitter Test <test@example.invalid> 0 +0000\n\nInitial\n")
  File.binwrite(File.join(git_dir, "HEAD"), "ref: refs/heads/main\n")
  File.binwrite(File.join(git_dir, "refs/heads/main"), "#{commit}\n")
  File.binwrite(File.join(root, "tracked.txt"), "after\n")
  entry = Canopus::Git::Index::Entry.new(path: "tracked.txt", oid: blob, mode: 0o100644, size: 7,
    mtime: 0, mtime_nsec: 0, ctime: 0, ctime_nsec: 0, dev: 0, ino: 0, uid: 0, gid: 0, stage: 0)
  File.binwrite(File.join(git_dir, "index"), Canopus::Git::Index.encode([entry]))
  repository = Canopus::Git::Repository.new(root)
  check(repository.head == commit && repository.branch == "main", "Git references")
  check(repository.commit.message == "Initial\n" && repository.tree.fetch("tracked.txt").oid == blob, "Git commit/tree")
  check(repository.blob("tracked.txt") == "before\n" && repository.object(blob) == ["blob", "before\n"], "Git loose objects")
  check(repository.index.to_a.first.path == "tracked.txt", "Git index enumerable")
  check(repository.status.any? { |item| item.path == "tracked.txt" && item.code == " M" }, "Git worktree status")
  hunk = repository.diff("tracked.txt").first
  check(hunk.old_text == "before\n" && hunk.new_text == "after\n", "Git diff")
  check(repository.revert_hunk("tracked.txt", hunk) == "before\n", "Git hunk revert")
  check(repository.blame("tracked.txt").first.commit == commit, "Git blame")
  check(Canopus::Git::Diff.unified("a\n", "b\n").include?("+b"), "unified diff")

  grid = Canopus::Terminal::Grid.new(columns: 20, rows: 3, scrollback: 4)
  replies = []
  vt = Canopus::Terminal::VT.new(grid) { |bytes| replies << bytes }
  vt.feed("\e[3m日本\e[0m\r\n\e]8;;https://example.invalid\aLink\e]8;;\a")
  check(grid[0, 0].width == 2 && grid[0, 0].attributes[:italic], "terminal Unicode/italic")
  check(grid.selection([0, 0], [4, 0]) == "日本", "terminal selection")
  check(grid.links(1).first[:url] == "https://example.invalid", "terminal OSC 8 link")
  vt.feed("\e[?2004h\e[?1000h\e[?1006h\e[6n")
  check(vt.paste("x") == "\e[200~x\e[201~" && replies.any?, "terminal paste/reply")
  check(vt.key(:up, control: true) == "\e[1;5A", "terminal modified key")
  check(vt.mouse(button: :left, column: 0, row: 0) == "\e[<0;1;1M", "terminal mouse")
  grid.scroll_up(2)
  check(grid.scrollback.length == 2 && grid.scrollback.to_a.first.first.text == "日", "tree-backed scrollback")
  grid.resize(columns: 25, rows: 4)
  check(grid.columns == 25 && grid.rows == 4, "terminal resize")

  plan = Canopus::Workspace::Edit::Plan.new(workspace, {"documentChanges" => []})
  check(plan.apply["applied"], "preflighted workspace edit")
  plan.close

  future = Canopus::LSP::Future.new(1)
  future.fulfill(42)
  check(future.await == 42, "LSP future")
  check(Kochab.parse('{/* comment */"a":1,}').value == {"a" => 1}, "JSONC dependency")
  check(Spica.filter("val", ["value"]).first.candidate == "value", "search dependency")
  window = Zaniah::Platform.open_window(width: 500, height: 240)
  controller = Canopus::Controller.new(workspace, window)
  controller.tick
  check(window.text_runs.any? { |_, _, text, _| text.include?("value") }, "headless editor render")
  check(window.device.pixels.bytesize == 500 * 240 * 4, "frame size")
ensure
  workspace&.close
  window&.on_close { true }
  window&.close
end
puts "public API smoke: editing/session/project/Git/terminal/excerpts/LSP/dependencies/headless passed"
