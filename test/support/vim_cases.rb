# frozen_string_literal: true

module VimCases
  def self.all
    cases = []
    operators = %w[d c y > < gu gU g~]
    base = "Alpha one+two THREE\n  four five-six\nseven EIGHT nine\n"
    motions = %w[h l w W b B e E ge gE 0 ^ $ j k gg G]
    operators.each do |operator|
      motions.each do |motion|
        [0, 8, 25].each do |start|
          keys = operator.chars + motion.chars
          keys += %w[X esc] if operator == "c"
          cases << {name: "#{operator}-#{motion}-#{start}", text: base, start: start, keys: keys}
        end
      end
      %w[f F t T].each do |find|
        keys = operator.chars + [find, "o"]
        keys += %w[X esc] if operator == "c"
        cases << {name: "#{operator}-#{find}o", text: "one two four\n", start: 6, keys: keys}
      end
      ["w", "W", "p", "(", ")", "b", "[", "]", "{", "}", "B", '"', "'", "`", "<", ">", "t"].each do |object|
        text, start = case object
        when "w", "W" then ["prefix one+two suffix", 10]
        when "p" then ["before\n\nfirst\nsecond\n\nafter\n", 10]
        when "(", ")", "b" then ["pre (outer (inner) tail) post", 19]
        when "[", "]" then ["pre [outer [inner] tail] post", 19]
        when "{", "}", "B" then ["pre {outer {inner} tail} post", 19]
        when "<", ">" then ["pre <outer <inner> tail> post", 19]
        when "t" then ["<div><b>inner</b> tail</div>", 18]
        else ["pre #{object}a \\#{object}b#{object} post", 7]
        end
        %w[i a].each do |around|
          keys = operator.chars + [around, object]
          keys += %w[X esc] if operator == "c"
          cases << {name: "#{operator}-#{around}#{object}", text: text, start: start, keys: keys}
        end
      end
    end
    ["v", "V", "ctrl-v"].each do |visual|
      operators.each do |operator|
        [%w[l l], %w[j l l], %w[k h h]].each do |motion|
          keys = [visual, *motion, *operator.chars]
          keys += %w[X esc] if operator == "c"
          cases << {name: "#{visual}-#{motion.join}-#{operator}", text: "abcdef\nghijkl\nmnopqr\n", start: 9, keys: keys}
        end
      end
    end
    extras = [
      ["count-before-and-after", "one two three four five six seven", 0, %w[2 d 3 w]],
      ["counted-inner-word", "one two three four", 0, %w[d 2 i w]],
      ["outer-counted-parens", "one (a (b) c) two", 8, %w[d 2 i (]],
      ["backward-percent", "a (one [two]) z", 12, %w[d %]],
      ["counted-insert", "abc", 0, %w[3 i X esc]],
      ["replace-backspace", "abcdef", 1, %w[R X Y backspace Z esc]],
      ["replace-short-line", "ab\ncd", 1, %w[9 r X]],
      ["line-yank-paste-eof", "one\ntwo", 4, %w[y y p]],
      ["line-delete-eof", "one\ntwo", 4, %w[d d]],
      ["change-line", "one\ntwo\nthree", 4, %w[c c X esc]],
      ["change-word-undo", "one two", 0, %w[c w X Y esc u]],
      ["insert-undo", "one", 0, %w[i X Y esc u]],
      ["find-till-repeat", "axbxcxd", 0, %w[t x ; ;]],
      ["find-reverse-repeat", "axbxcxd", 0, %w[f x ; , ;]],
      ["named-append", "one two three", 0, ['"', "a", "y", "w", "w", '"', "A", "y", "w", '"', "a", "p"]],
      ["blackhole-register", "one two three", 0, ["y", "w", '"', "_", "d", "w", "p"]],
      ["macro-repeat", "abcd", 0, %w[q a x q 2 @ a]],
      ["join-three", "one\n two\nthree\nfour", 0, %w[3 J]],
      ["unicode-motion", "あいう αβγ emoji", 0, %w[l d w]],
      ["quote-closing", 'pre "inside" post', 11, %w[d i "]],
      ["tag-inner", '<div><b>inside</b></div>', 9, %w[d i t]]
    ]
    extras += [
      ["block-insert", "abcd\nefgh\nijkl", 1, %w[ctrl-v j l I X Y esc]],
      ["block-append", "abcd\nefgh\nijkl", 1, %w[ctrl-v j l A X Y esc]],
      ["block-append-short", "abcd\ne\nijkl", 2, %w[ctrl-v j j l A X esc]],
      ["block-insert-short", "abcd\ne\nijkl", 2, %w[ctrl-v j j l I X esc]],
      ["block-replace", "abcd\nefgh\nijkl", 1, %w[ctrl-v j l r X]],
      ["visual-replace", "abcd\nefgh", 1, %w[v j l r X]],
      ["block-yank-paste", "abcd\nefgh\nijkl", 1, %w[ctrl-v j l y j p]],
      ["visual-paste", "one two three", 0, %w[y w w v l l p]],
      ["visual-line-paste-char", "one two\nthree four\nfive", 0, %w[y w j V p]],
      ["visual-char-paste-line", "one\ntwo three", 0, %w[y y j v l p]],
      ["visual-block-paste", "abcd\nefgh\nijkl", 1, %w[ctrl-v j l y j ctrl-v k l p]],
      ["macro-register-paste", "abcd", 0, ["q", "a", "x", "q", '"', "a", "p"]],
      ["mark-motion-delete", "one two\nthree four\nfive", 0, %w[j m a g g d ` a]],
      ["mark-line-delete", "one two\nthree four\nfive", 0, %w[j m a g g d ' a]],
      ["sentence-inner", "One sentence. Two words! Last one.", 18, %w[d i s]],
      ["sentence-around", "One sentence. Two words! Last one.", 18, %w[d a s]],
      ["counted-around-word", "one two three four", 0, %w[d 2 a w]],
      ["change-word-twice", "one two three four", 2, %w[c 2 w X esc]],
      ["dot-count-insert", "abc def ghi", 0, %w[2 i X esc w .]],
      ["normal-right-boundary", "abc\ndef", 0, %w[9 l x]],
      ["normal-left-boundary", "abc\ndef", 5, %w[9 h x]],
      ["search-operator", "one two three two end", 0, ["d", "/", "t", "w", "o", "enter"]]
    ]
    extras += [
      ["block-change-two", "abcd\nefgh", 1, %w[ctrl-v j l c X Y esc]],
      ["delete-word-before-newline", "one two\nthree four", 4, %w[d w]],
      ["yank-word-before-newline", "one two\nthree four", 4, %w[y w]],
      ["change-whitespace", "one   two", 3, %w[c w X esc]],
      ["word-empty-line", "one\n\ntwo\nthree", 0, %w[w]],
      ["word-through-empty-line", "one\n\ntwo\nthree", 0, %w[2 w]],
      ["paragraph-delete", "one\ntwo\n\nthree\nfour", 2, %w[d }]],
      ["counted-inner-three", "one two three four", 0, %w[d 3 i w]],
      ["nested-inner-count", "outer (one (two (three)) end)", 17, %w[d 2 i (]],
      ["undo-delete", "one two three", 4, %w[d w u]],
      ["undo-indent", "one\n two\nthree", 5, %w[> > u]],
      ["visual-block-dot", "abcd\nefgh\nijkl\nmnop", 0, %w[ctrl-v j l d j .]],
      ["substitute-first", "one one\none one", 0, [":", *"%s/one/two/".chars, "enter"]],
      ["substitute-match", "one two", 0, [":", *"s/one/[&]/".chars, "enter"]]
    ]
    extras += [
      ["visual-substitute", "one two\none two\none two", 0, ["V", "j", ":", *"s/one/NEW/".chars, "enter"]],
      ["plain-reindent", "one\n   two\n      three\nfour", 0, %w[= G]],
      ["search-count-reset", "a b a b a b a", 0, ["d", "2", "/", "a", "enter", "/", "b", "enter"]],
      ["visual-block-gv", "abcd\nefgh\nijkl", 1, %w[ctrl-v j l esc g v y]]
    ]
    extras += [
      ["macro-count-undo", "abcdefgh", 0, %w[q a x q 2 @ a u]],
      ["macro-insert-undo", "abcdefgh", 0, %w[q a i X esc q @ a u]],
      ["macro-with-undo", "abcdefgh", 0, %w[q a x u l q @ a]],
      ["counted-case-after-count", "one two\nthree four\nfive six", 0, %w[2 y y g U G]],
      ["case-line-repeat", "one\ntwo\nthree", 0, %w[g U U j .]],
      ["change-line-repeat", "one\ntwo\nthree", 0, %w[c c X esc j .]],
      ["visual-yank-gv", "abc def ghi", 2, %w[v l l y g v d]]
    ]
    %w[v V ctrl-v].each do |mode|
      %w[> <].each do |operator|
        extras << ["visual-counted-shift-#{mode}-#{operator}", "a        bcd\ne        fgh\nijkl", 1, [mode, "j", "l", "2", operator]]
      end
    end
    ["\tEF", "あいう"].each_with_index do |middle, index|
      [%w[d], %w[y], %w[c X esc], %w[r X], %w[I X esc], %w[A X esc], %w[>], %w[<], %w[y j p]].each do |operation|
        [%w[j l], %w[j], %w[j j]].each do |motion|
          extras << ["block-cells-#{index}-#{motion.join}-#{operation.join}", "abcd\n#{middle}\nijkl", 1, ["ctrl-v", *motion, *operation]]
        end
      end
      extras << ["block-cells-paste-#{index}", "abcd\n#{middle}\nijkl", 1, %w[y l ctrl-v j j l p]]
    end
    extras.each { |name, text, start, keys| cases << {name: name, text: text, start: start, keys: keys} }
    cases
  end
end
