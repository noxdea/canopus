# frozen_string_literal: true

class Canopus::Language::BackgroundAnalysis::Job
  attr_accessor :future, :inner
  def cancel
    @cancelled = true
    @inner&.cancel
  end
  def check!
    raise Zaniah::Task::Cancelled, "superseded language analysis" if @cancelled
  end
end
