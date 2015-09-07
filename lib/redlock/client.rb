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

    def testing=(mode)
      @testing_mode = mode
    end

    # Locks a resource for a given time.
    #
    # If given a block, if the lock is obtained, it will yield and unlock afterwards. If the lock is not obtained, it will return false and not yield. Note that block mode adds a small amount of time overhead.
    #
    # +resource+:: the resource (or key) string to be locked.
    # +ttl+:: The time-to-live in ms for the lock. If > 1 second, broken into many 1-second locks (and a final remainder lock), effectively unlocking in case of a kill 9 (SIGKILL)
    # +extend+: A lock ("lock_info") to extend.
    def lock(resource, ttl, extend: nil)
      if block_given?
        raise "can't extend a lock with block mode" if extend
        lock_info = nil
        resolved = false
        locked = nil
        t = Thread.new do
          quotient = ttl / 1000
          remainder = ttl % 1000
          started_at = Time.now.to_f
          quotient.times do
            lock_info = try_lock_instances resource, 1000, lock_info
            if not lock_info
              if resolved
                # we failed to keep the lock after at first getting it
                raise "failed to keep lock after #{Time.now.to_f - started_at} seconds for resource #{resource_key}"
              else
                # we never got the lock
                resolved = true
                locked = false
                Thread.exit
              end
            end
            locked = true
            resolved = true
            sleep 0.9
          end
          elapsed = Time.now.to_f - started_at
          extra = quotient > 0 ? ((quotient - elapsed).to_f * 1000).round : 0 # so let's say we did 0.9 for a 1.1-second lock ... then we would add an extra 0.1 to the existing 0.1 remainder
          lock_info = try_lock_instances resource, (remainder + extra), lock_info
          raise "failed to keep lock after #{Time.now.to_f - started_at} seconds for resource #{resource_key}" unless lock_info
          resolved = true
          locked = true
        end
        tries_left = 10
        until resolved or tries_left < 1
          tries_left -= 1
          sleep 0.1
        end
        raise "didn't get lock resolution in 1 second" unless resolved
        memo = if locked
          begin
            yield
          ensure
            unlock(lock_info) if lock_info
          end
          true
        else
          false
        end
        t.join if t.status.nil?
        memo
      else
        try_lock_instances resource, ttl, extend
      end
    end

    # Unlocks a resource.
    # Params:
    # +lock_info+:: the lock that has been acquired when you locked the resource.
    def unlock(lock_info)
      return if @testing_mode == :bypass

      @servers.each { |s| s.unlock(lock_info[:resource], lock_info[:value]) }
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
      EXTEND_SCRIPT = <<-eos
        if redis.call( "get", KEYS[1] ) == ARGV[1] then
          if redis.call( "set", KEYS[1], ARGV[1], "XX", "PX", ARGV[2] ) then
            return "OK"
          end
        else
          return redis.call( "set", KEYS[1], ARGV[1], "NX", "PX", ARGV[2] )
        end
      eos

      def initialize(connection)
        if connection.respond_to?(:client)
          @redis = connection
        else
          @redis  = Redis.new(connection)
        end

        @unlock_script_sha = @redis.script(:load, UNLOCK_SCRIPT)
        @extend_script_sha = @redis.script(:load, EXTEND_SCRIPT)
      end

      def lock(resource, val, ttl, extend)
        if extend
          @redis.evalsha(@extend_script_sha, keys: [resource], argv: [extend[:value], ttl])
        else
          @redis.set(resource, val, nx: true, px: ttl)
        end
      end

      def unlock(resource, val)
        @redis.evalsha(@unlock_script_sha, keys: [resource], argv: [val])
      rescue
        # Nothing to do, unlocking is just a best-effort attempt.
      end
    end

    def try_lock_instances(resource, ttl, extend)
      if @testing_mode == :bypass
        return {
          validity: ttl,
          resource: resource,
          value: SecureRandom.uuid
        }
      elsif @testing_mode == :fail
        return false
      end

      @retry_count.times do |i|
        lock_info = lock_instances(resource, ttl, extend)
        return lock_info if lock_info

        # Wait a random delay before retrying
        sleep(rand(@retry_delay).to_f / 1000)
      end

      false
    end

    def lock_instances(resource, ttl, extend)
      value = SecureRandom.uuid

      locked, time_elapsed = timed do
        @servers.select { |s| s.lock(resource, value, ttl, extend) }.size
      end

      validity = ttl - time_elapsed - drift(ttl)
      used_value = extend ? extend[:value] : value

      if locked >= @quorum && validity >= 0
        { validity: validity, resource: resource, value: used_value }
      else
        @servers.each { |s| s.unlock(resource, used_value) }
        false
      end
    end

    def drift(ttl)
      # Add 2 milliseconds to the drift to account for Redis expires
      # precision, which is 1 millisecond, plus 1 millisecond min drift
      # for small TTLs.
      drift = (ttl * CLOCK_DRIFT_FACTOR).to_i + 2
    end

    def timed
      start_time = (Time.now.to_f * 1000).to_i
      [yield, (Time.now.to_f * 1000).to_i - start_time]
    end
  end
end
