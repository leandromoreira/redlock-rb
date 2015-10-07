require 'redlock/version'

module Redlock
  autoload :Client, 'redlock/client'

  LockError = Class.new(StandardError)
end
