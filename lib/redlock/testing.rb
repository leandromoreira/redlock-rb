require 'redlock'

module Redlock
  class Client
    class << self
      attr_accessor :testing_mode
    end

    def testing_mode=(mode)
      warn 'DEPRECATION WARNING: Instance-level `testing_mode` has been removed, and this ' +
        'setter will be removed in the future. Please set the testing mode on the `Redlock::Client` ' +
        'instead, e.g. `Redlock::Client.testing_mode = :bypass`.'

      self.class.testing_mode = mode
    end

    alias_method :try_lock_instances_without_testing, :try_lock_instances

    def try_lock_instances(resource, ttl, options)
      if self.class.testing_mode == :bypass
        {
          validity: ttl,
          resource: resource,
          value: options[:extend] ? options[:extend].fetch(:value) : SecureRandom.uuid
        }
      elsif self.class.testing_mode == :fail
        false
      else
        try_lock_instances_without_testing resource, ttl, options
      end
    end

    alias_method :unlock_without_testing, :unlock

    def unlock(lock_info)
      unlock_without_testing lock_info unless self.class.testing_mode == :bypass
    end

    class RedisInstance
      alias_method :load_scripts_without_testing, :load_scripts

      def load_scripts
        load_scripts_without_testing unless Redlock::Client.testing_mode == :bypass
      rescue RedisClient::CommandError
        # FakeRedis doesn't have #script, but doesn't need it either.
        raise unless defined?(::FakeRedis)
      rescue NoMethodError
        raise unless defined?(::MockRedis)
      end
    end
  end
end
