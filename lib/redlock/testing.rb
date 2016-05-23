module Redlock
  class Client
    attr_writer :testing_mode

    alias_method :try_lock_instances_without_testing, :try_lock_instances

    def try_lock_instances(resource, ttl, options)
      if @testing_mode == :bypass
        {
          validity: ttl,
          resource: resource,
          value: options[:extend] ? options[:extend].fetch(:value) : SecureRandom.uuid
        }
      elsif @testing_mode == :fail
        false
      else
        try_lock_instances_without_testing resource, ttl, options
      end
    end

    alias_method :unlock_without_testing, :unlock

    def unlock(lock_info)
      unlock_without_testing lock_info unless @testing_mode == :bypass
    end

    class RedisInstance
      alias_method :load_scripts_without_testing, :load_scripts

      def load_scripts
        load_scripts_without_testing
      rescue Redis::CommandError
        # FakeRedis doesn't have #script, but doesn't need it either.
        raise unless defined?(::FakeRedis)
      rescue NoMethodError
        raise unless defined?(::MockRedis)
      end
    end
  end
end
