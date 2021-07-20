require 'redlock/version'

module Redlock
  autoload :Client, 'redlock/client'
  autoload :Scripts, 'redlock/scripts'

  class LockError < StandardError
    def initialize(resource)
      super "failed to acquire lock on '#{resource}'".freeze
    end
  end
end
