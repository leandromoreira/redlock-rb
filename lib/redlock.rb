require 'redlock/version'

module Redlock
  autoload :Client, 'redlock/client'

  class LockException < StandardError; end
end
