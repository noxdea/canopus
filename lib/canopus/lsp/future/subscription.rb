# frozen_string_literal: true

class Canopus::LSP::Future::Subscription
  def initialize(&detach) = @detach = detach
  def detach
    callback, @detach = @detach, nil
    callback&.call
  end
end
