# frozen_string_literal: true

require "porrima"

module Canopus
  module Git
    module Diff
      Edit = Porrima::Edit
      Hunk = Porrima::Hunk
      module_function

      def edits(before, after) = Porrima.edits(before, after)
      def hunks(before, after, context: 3) = Porrima.hunks(before, after, context: context)
      def revert(text, hunk) = Porrima.revert(text, hunk)

      def unified(before, after, old_name: "a/file", new_name: "b/file", context: 3)
        Porrima.unified(before, after, old_name: old_name, new_name: new_name, context: context)
      end
    end
  end
end
