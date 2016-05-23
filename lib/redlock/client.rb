require 'redis'
require 'securerandom'

module Redlock
  class Client
    DEFAULT_REDIS_URLS    = ['redis://localhost:6379']
    DEFAULT_REDIS_TIMEOUT = 0.1
    DEFAULT_RETRY_COUNT   = 3
    DEFAULT_RETRY_DELAY   = 200
    CLOCK_DRIFT_FACTOR    = 0.01

    # Create a distributed lock manager implementing redlock algorithm.
    # Params:
    # +servers+:: The array of redis connection URLs or Redis connection instances. Or a mix of both.
    # +options+:: You can override the default value for `retry_count` and `retry_delay`.
    #    * `retry_count`   being how many times it'll try to lock a resource (default: 3)
    #    * `retry_delay`   being how many ms to sleep before try to lock again (default: 200)
    #    * `redis_timeout` being how the Redis timeout will be set in seconds (default: 0.1)
    def initialize(servers = DEFAULT_REDIS_URLS, options = {})
      redis_timeout = options[:redis_timeout] || DEFAULT_REDIS_TIMEOUT
      @servers = servers.map do |server|
        if server.is_a?(String)
          RedisInstance.new(url: server, timeout: redis_timeout)
        else
          RedisInstance.new(server)
        end
      end
      @quorum = servers.length / 2 + 1
      @retry_count = options[:retry_count] || DEFAULT_RETRY_COUNT
      @retry_delay = options[:retry_delay] || DEFAULT_RETRY_DELAY
    end

    # Locks a resource for a given time.
    # Params:
    # +resource+:: the resource (or key) string to be locked.
    # +ttl+:: The time-to-live in ms for the lock.
    # +extend+: A lock ("lock_info") to extend.
    # +block+:: an optional block to be executed; after its execution, the lock (if successfully
    # acquired) is automatically unlocked.
    def lock(resource, ttl, options = {}, &block)
      lock_info = try_lock_instances(resource, ttl, options)

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
    def lock!(*args)
      fail 'No block passed' unless block_given?

      lock(*args) do |lock_info|
        raise LockError, 'failed to acquire lock' unless lock_info
        return yield
      end
    end

    private

    class RedisInstance
      UNLOCK_SCRIPT = <<-eos
        if redis.call("get",KEYS[1]) == ARGV[1] then
          return redis.call("del",KEYS[1])
        else
          return 0
        end
      eos

      # thanks to https://github.com/sbertrang/redis-distlock/blob/master/lib/Redis/DistLock.pm
      # also https://github.com/sbertrang/redis-distlock/issues/2 which proposes the value-checking
      # and @maltoe for https://github.com/leandromoreira/redlock-rb/pull/20#discussion_r38903633
      LOCK_SCRIPT = <<-eos
        if redis.call("exists", KEYS[1]) == 0 or redis.call("get", KEYS[1]) == ARGV[1] then
          return redis.call("set", KEYS[1], ARGV[1], "PX", ARGV[2])
        end
      eos

      EXTEND_LIFE_SCRIPT = <<-eos
        if redis.call("get", KEYS[1]) == ARGV[1] then
          redis.call("expire", KEYS[1], ARGV[2])
          return 0
        else
          return 1
        end
      eos

      def initialize(connection)
        if connection.respond_to?(:client)
          @redis = connection
        else
          @redis  = Redis.new(connection)
        end

        load_scripts
      end

      def lock(resource, val, ttl)
        recover_from_script_flush do
          @redis.evalsha @lock_script_sha, keys: [resource], argv: [val, ttl]
        end
      end

      def extend(resource, val, ttl)
        recover_from_script_flush do
          rc = @redis.evalsha @extend_life_script_sha, keys: [resource], argv: [val, ttl]
          rc == 0
        end
      end

      def unlock(resource, val)
        recover_from_script_flush do
          @redis.evalsha @unlock_script_sha, keys: [resource], argv: [val]
        end
      rescue
        # Nothing to do, unlocking is just a best-effort attempt.
      end

      private

      def load_scripts
        @unlock_script_sha = @redis.script(:load, UNLOCK_SCRIPT)
        @lock_script_sha = @redis.script(:load, LOCK_SCRIPT)
        @extend_life_script_sha = @redis.script(:load, EXTEND_LIFE_SCRIPT)
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
      tries = options[:extend] ? 1 : @retry_count

      tries.times do
        lock_info = lock_instances(resource, ttl, options)
        return lock_info if lock_info

        # Wait a random delay before retrying
        sleep(rand(@retry_delay).to_f / 1000)
      end

      false
    end

    def lock_instances(resource, ttl, options)
      value  = options[:extend] ? options[:extend].fetch(:value) : SecureRandom.uuid
      method = options[:extend_life] ? :extend : :lock

      locked, time_elapsed = timed do
        @servers.select { |s| s.send(method, resource, value, ttl) }.size
      end

      validity = ttl - time_elapsed - drift(ttl)

      if locked >= @quorum && validity >= 0
        { validity: validity, resource: resource, value: value }
      else
        @servers.each { |s| s.unlock(resource, value) }
        false
      end
    end

    def drift(ttl)
      # Add 2 milliseconds to the drift to account for Redis expires
      # precision, which is 1 millisecond, plus 1 millisecond min drift
      # for small TTLs.
      (ttl * CLOCK_DRIFT_FACTOR).to_i + 2
    end

    def timed
      start_time = (Time.now.to_f * 1000).to_i
      [yield, (Time.now.to_f * 1000).to_i - start_time]
    end
  end
end
