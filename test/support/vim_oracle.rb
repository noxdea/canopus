# frozen_string_literal: true

require "json"
require "tmpdir"
require "open3"

module VimOracle
  KEYS = {"esc" => "\e", "enter" => "\r", "tab" => "\t", "backspace" => "\b", "ctrl-v" => "\x16", "ctrl-r" => "\x12"}.freeze
  def self.run(cases, executable: ENV.fetch("VIM", "vim"))
    Dir.mktmpdir("vim-differential-") do |directory|
      input, output, script = %w[input.json output.json commands.vim].map { |name| File.join(directory, name) }
      data = cases.map do |item|
        prefix = item.fetch(:text).byteslice(0, item.fetch(:start))
        row = prefix.count("\n")
        column = prefix.bytesize - ((prefix.b.rindex("\n".b) || -1) + 1)
        item.merge(row: row + 1, column: column + 1, sequence: item.fetch(:keys).map { |key| KEYS.fetch(key, key) }.join)
      end
      File.write(input, JSON.generate(data))
      File.write(script, <<~VIM)
        set nocompatible nomore shortmess+=I encoding=utf-8
        set expandtab shiftwidth=4 tabstop=4 softtabstop=4 autoindent nojoinspaces
        let cases = json_decode(join(readfile('#{input}'), "\\n"))
        let results = []
        for c in cases
          enew!
          setlocal noswapfile nofixendofline
          let rows = split(c.text, "\\n", 1)
          let eol = c.text =~ "\\n$"
          if eol | call remove(rows, -1) | endif
          if empty(rows) | let rows = [''] | endif
          call setline(1, rows)
          if eol | setlocal endofline | else | setlocal noendofline | endif
          call setreg('"', '')
          call setreg('a', '')
          call cursor(c.row, c.column)
          call feedkeys(c.sequence, 'xt')
          let rows = getline(1, '$')
          let text = join(rows, "\\n") . (&endofline && rows != [''] ? "\\n" : '')
          let offset = max([0, line2byte(line('.')) + col('.') - 2])
          call add(results, {'name': c.name, 'text': text, 'cursor': offset, 'register': getreg('"'), 'type': getregtype('"')})
        endfor
        call writefile([json_encode(results)], '#{output}')
        qa!
      VIM
      stdout, stderr, status = Open3.capture3(executable, "-Nu", "NONE", "-i", "NONE", "-n", "-es", "-V1", "-S", script)
      raise "Vim oracle failed: #{stdout} #{stderr}" unless status.success? && File.file?(output)
      JSON.parse(File.read(output))
    end
  end
end
