# Vim mode

Set `"vim_mode": true` or use the command palette to enable modal editing. Canopus
implements its own Vim-compatible command parser; it does not launch Vim.

Modes include Normal, Insert, Replace, Visual, Visual Line, and Visual Block.
Supported motions include character, word/WORD, line, paragraph, matching-pair,
find-character, mark, and page motions. Counts compose with operators.

Operators include delete, change, yank, shift, reindent, case conversion, and
swap case. Text objects cover words, sentences, paragraphs, nested brackets,
quotes, and tags. Visual-block operations use display cells, preserving partial
tabs and wide Unicode glyphs. Undo/redo, repeat, joins, paste, registers, marks,
macros, search, and substitution are supported.

The Ex subset includes line addresses, `w [path]`, `reg`, tab/shift width and
expand-tab options, relative numbers, and `s` with `g` and `i`. Other Ex commands
are forwarded to workspace commands.

Search and substitution use Ruby regular expressions, not Vim's magic dialect.
Vimscript, arbitrary shell commands, and user mappings are not interpreted.
Clipboard registers `+` and `*` are in-memory registers rather than OS clipboard
integrations. Counts are capped at 10,000; macro playback allows 10 nested calls
and 10,000 keys.
