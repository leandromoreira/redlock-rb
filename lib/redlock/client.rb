require 'redis'
require 'securerandom'

module Redlock
  include Scripts

  class Client
    DEFAULT_REDIS_HOST    = ENV["DEFAULT_REDIS_HOST"] || "localhost"
    DEFAULT_REDIS_PORT    = ENV["DEFAULT_REDIS_PORT"] || "6379"
    DEFAULT_REDIS_URLS    = ["redis://#{DEFAULT_REDIS_HOST}:#{DEFAULT_REDIS_PORT}"]
    DEFAULT_REDIS_TIMEOUT = 0.1
    DEFAULT_RETRY_COUNT   = 3
    DEFAULT_RETRY_DELAY   = 200
    DEFAULT_RETRY_JITTER  = 50
    CLOCK_DRIFT_FACTOR    = 0.01

    ##
    # Returns default time source function depending on CLOCK_MONOTONIC availability.
    #
    def self.default_time_source
      if defined?(Process::CLOCK_MONOTONIC)
        proc { (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).to_i }
      else
        proc { (Time.now.to_f * 1000).to_i }
      end
    end

    # Create a distributed lock manager implementing redlock algorithm.
    # Params:
    # +servers+:: The array of redis connection URLs or Redis connection instances. Or a mix of both.
    # +options+::
    #    * `retry_count`   being how many times it'll try to lock a resource (default: 3)
    #    * `retry_delay`   being how many ms to sleep before try to lock again (default: 200)
    #    * `retry_jitter`  being how many ms to jitter retry delay (default: 50)
    #    * `redis_timeout` being how the Redis timeout will be set in seconds (default: 0.1)
    #    * `time_source`   being a callable object returning a monotonic time in milliseconds
    #                      (default: see #default_time_source)
    def initialize(servers = DEFAULT_REDIS_URLS, options = {})
      redis_timeout = options[:redis_timeout] || DEFAULT_REDIS_TIMEOUT
      @servers = servers.map do |server|
        if server.is_a?(String)
          RedisInstance.new(url: server, timeout: redis_timeout)
        else
          RedisInstance.new(server)
        end
      end
      @quorum = (servers.length / 2).to_i + 1
      @retry_count = options[:retry_count] || DEFAULT_RETRY_COUNT
      @retry_delay = options[:retry_delay] || DEFAULT_RETRY_DELAY
      @retry_jitter = options[:retry_jitter] || DEFAULT_RETRY_JITTER
      @time_source = options[:time_source] || self.class.default_time_source
    end

    # Locks a resource for a given time.
    # Params:
    # +resource+:: the resource (or key) string to be locked.
    # +ttl+:: The time-to-live in ms for the lock.
    # +options+:: Hash of optional parameters
    #  * +retry_count+: see +initialize+
    #  * +retry_delay+: see +initialize+
    #  * +retry_jitter+: see +initialize+
    #  * +extend+: A lock ("lock_info") to extend.
    #  * +extend_only_if_locked+: Boolean, if +extend+ is given, only acquire lock if currently held
    #  * +extend_only_if_life+: Deprecated, same as +extend_only_if_locked+
    #  * +extend_life+: Deprecated, same as +extend_only_if_locked+
    # +block+:: an optional block to be executed; after its execution, the lock (if successfully
    # acquired) is automatically unlocked.
    def lock(resource, ttl, options = {}, &block)
      lock_info = try_lock_instances(resource, ttl, options)
      if options[:extend_only_if_life] && !Gem::Deprecate.skip
        warn 'DEPRECATION WARNING: The `extend_only_if_life` option has been renamed `extend_only_if_locked`.'
        options[:extend_only_if_locked] = options[:extend_only_if_life]
      end
      if options[:extend_life] && !Gem::Deprecate.skip
        warn 'DEPRECATION WARNING: The `extend_life` option has been renamed `extend_only_if_locked`.'
        options[:extend_only_if_locked] = options[:extend_life]
      end

      if block_given?
        begin
          yield lock_info
          !!lock_info
        ensure
          unlock(lock_info) if lock_info
        end
      else
        lock_info
      end
    end

    # Unlocks a resource.
    # Params:
    # +lock_info+:: the lock that has been acquired when you locked the resource.
    def unlock(lock_info)
      @servers.each { |s| s.unlock(lock_info[:resource], lock_info[:value]) }
    end

    # Locks a resource, executing the received block only after successfully acquiring the lock,
    # and returning its return value as a result.
    # See Redlock::Client#lock for parameters.
    def lock!(resource, *args)
      fail 'No block passed' unless block_given?

      lock(resource, *args) do |lock_info|
        raise LockError, resource unless lock_info
        return yield
      end
    end

    # Gets remaining ttl of a resource. The ttl is returned if the holder
    # currently holds the lock and it has not expired, otherwise the method
    # returns nil.
    # Params:
    # +lock_info+:: the lock that has been acquired when you locked the resource
    def get_remaining_ttl_for_lock(lock_info)
      ttl_info = try_get_remaining_ttl(lock_info[:resource])
      return nil if ttl_info.nil? || ttl_info[:value] != lock_info[:value]
      ttl_info[:ttl]
    end

    # Gets remaining ttl of a resource. If there is no valid lock, the method
    # returns nil.
    # Params:
    # +resource+:: the name of the resource (string) for which to check the ttl
    def get_remaining_ttl_for_resource(resource)
      ttl_info = try_get_remaining_ttl(resource)
      return nil if ttl_info.nil?
      ttl_info[:ttl]
    end

    # Checks if a resource is locked
    # Params:
    # +lock_info+:: the lock that has been acquired when you locked the resource
    def locked?(resource)
      ttl = get_remaining_ttl_for_resource(resource)
      !(ttl.nil? || ttl.zero?)
    end

    # Checks if a lock is still valid
    # Params:
    # +lock_info+:: the lock that has been acquired when you locked the resource
    def valid_lock?(lock_info)
      ttl = get_remaining_ttl_for_lock(lock_info)
      !(ttl.nil? || ttl.zero?)
    end

    private

    class RedisInstance
      module ConnectionPoolLike
        def with
          yield self
        end
      end

      def initialize(connection)
        if connection.respond_to?(:with)
          @redis = connection
        else
          if connection.respond_to?(:client)
            @redis = connection
          else
            @redis = Redis.new(connection)
          end
          @redis.extend(ConnectionPoolLike)
        end
      end

      def lock(resource, val, ttl, allow_new_lock)
        recover_from_script_flush do
          @redis.with { |conn| conn.evalsha Scripts::LOCK_SCRIPT_SHA, keys: [resource], argv: [val, ttl, allow_new_lock] }
        end
      rescue Redis::BaseConnectionError
        false
      end

      def unlock(resource, val)
        recover_from_script_flush do
          @redis.with { |conn| conn.evalsha Scripts::UNLOCK_SCRIPT_SHA, keys: [resource], argv: [val] }
        end
      rescue
        # Nothing to do, unlocking is just a best-effort attempt.
      end

      def get_remaining_ttl(resource)
        recover_from_script_flush do
          @redis.with { |conn| conn.evalsha Scripts::PTTL_SCRIPT_SHA, keys: [resource] }
        end
      rescue Redis::BaseConnectionError
        nil
      end

      private

      def load_scripts
        scripts = [
          Scripts::UNLOCK_SCRIPT,
          Scripts::LOCK_SCRIPT,
          Scripts::PTTL_SCRIPT
        ]

        scripts.each do |script|
          @redis.with { |conn| conn.script(:load, script) }
        end
      end

      def recover_from_script_flush
        retry_on_noscript = true
        begin
          yield
        rescue Redis::CommandError => e
          # When somebody has flushed the Redis instance's script cache, we might
          # want to reload our scripts. Only attempt this once, though, to avoid
          # going into an infinite loop.
          if retry_on_noscript && e.message.include?('NOSCRIPT')
            load_scripts
            retry_on_noscript = false
            retry
          else
            raise
          end
        end
      end
    end

    def try_lock_instances(resource, ttl, options)
      retry_count = options[:retry_count] || @retry_count
      tries = options[:extend] ? 1 : (retry_count + 1)

      tries.times do |attempt_number|
        # Wait a random delay before retrying.
        sleep(attempt_retry_delay(attempt_number, options)) if attempt_number > 0

        lock_info = lock_instances(resource, ttl, options)
        return lock_info if lock_info
      end

      false
    end

    def attempt_retry_delay(attempt_number, options)
      retry_delay = options[:retry_delay] || @retry_delay
      retry_jitter = options[:retry_jitter] || @retry_jitter

      retry_delay =
        if retry_delay.respond_to?(:call)
          retry_delay.call(attempt_number)
        else
          retry_delay
        end

      (retry_delay + rand(retry_jitter)).to_f / 1000
    end

    def lock_instances(resource, ttl, options)
      value = (options[:extend] || { value: SecureRandom.uuid })[:value]
      allow_new_lock = options[:extend_only_if_locked] ? 'no' : 'yes'

      locked, time_elapsed = timed do
        @servers.select { |s| s.lock resource, value, ttl, allow_new_lock }.size
      end

      validity = ttl - time_elapsed - drift(ttl)

      if locked >= @quorum && validity >= 0
        { validity: validity, resource: resource, value: value }
      else
        @servers.each { |s| s.unlock(resource, value) }
        false
      end
    end

    def try_get_remaining_ttl(resource)
      # Responses from the servers are a 2 tuple of format [lock_value, ttl].
      # The lock_value is nil if it does not exist. Since servers may have
      # different lock values, the responses are grouped by the lock_value and
      # transofrmed into a hash: { lock_value1 => [ttl1, ttl2, ttl3],
      # lock_value2 => [ttl4, tt5] }
      ttls_by_value, time_elapsed = timed do
        @servers.map { |s| s.get_remaining_ttl(resource) }
          .select { |ttl_tuple| ttl_tuple&.first }
          .group_by(&:first)
          .transform_values { |ttl_tuples| ttl_tuples.map { |t| t.last } }
      end

      # Authoritative lock value is that which is returned by the majority of
      # servers
      authoritative_value, ttls =
        ttls_by_value.max_by { |(lock_value, ttls)| ttls.length }

      if ttls && ttls.size >= @quorum
        # Return the  minimum TTL of an N/2+1 selection. It will always be
        # correct (it will guarantee that at least N/2+1 servers have a TTL that
        # value or longer)
        min_ttl = ttls.sort.last(@quorum).first
        min_ttl = min_ttl - time_elapsed - drift(min_ttl)
        { value: authoritative_value, ttl: min_ttl }
      else
        # No lock_value is authoritatively held for the resource
        nil
      end
    end

    def drift(ttl)
      # Add 2 milliseconds to the drift to account for Redis expires
      # precision, which is 1 millisecond, plus 1 millisecond min drift
      # for small TTLs.
      (ttl * CLOCK_DRIFT_FACTOR).to_i + 2
    end

    def timed
      start_time = @time_source.call()
      [yield, @time_source.call() - start_time]
    end
  end
end
