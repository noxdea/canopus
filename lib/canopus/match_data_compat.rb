# frozen_string_literal: true

unless MatchData.method_defined?(:byteoffset) && MatchData.method_defined?(:bytebegin)
  class MatchData
    unless method_defined?(:byteoffset)
      def byteoffset(index)
        first, last = offset(index)
        first && [string[0...first].bytesize, string[0...last].bytesize]
      end
    end

    unless method_defined?(:bytebegin)
      def bytebegin(index) = byteoffset(index)&.first
      def byteend(index) = byteoffset(index)&.last
    end
  end
end
