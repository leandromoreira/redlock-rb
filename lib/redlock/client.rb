require 'redis'
require 'securerandom'

module Redlock
  class Client
    DEFAULT_REDIS_URLS  = ['redis://localhost:6379']
    DEFAULT_RETRY_COUNT = 3
    DEFAULT_RETRY_DELAY = 200
    CLOCK_DRIFT_FACTOR  = 0.01

    # Create a distributed lock manager implementing redlock algorithm.
    # Params:
    # +server_urls+:: the array of redis hosts.
    # +options+:: You can override the default value for `retry_count` and `retry_delay`.
    #    * `retry_count` being how many times it'll try to lock a resource (default: 3)
    #    * `retry_delay` being how many ms to sleep before try to lock again (default: 200)
    def initialize(server_urls = DEFAULT_REDIS_URLS, options = {})
      @servers = server_urls.map { |url| RedisInstance.new(url) }
      @quorum = server_urls.length / 2 + 1
      @retry_count = options[:retry_count] || DEFAULT_RETRY_COUNT
      @retry_delay = options[:retry_delay] || DEFAULT_RETRY_DELAY
    end

    # Locks a resource for a given time.
    # Params:
    # +resource+:: the resource (or key) string to be locked.
    # +ttl+:: The time-to-live in ms for the lock.
    # +block+:: an optional block that automatically unlocks the lock.
    def lock(resource, ttl, &block)
      lock_info = try_lock_instances(resource, ttl)

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

    private

    class RedisInstance
      UNLOCK_SCRIPT = <<-eos
        if redis.call("get",KEYS[1]) == ARGV[1] then
          return redis.call("del",KEYS[1])
        else
          return 0
        end
      eos

      def initialize(url)
        @redis = Redis.new(url: url)
      end

      def lock(resource, val, ttl)
        @redis.client.call([:set, resource, val, :nx, :px, ttl])
      end

      def unlock(resource, val)
        @redis.client.call([:eval, UNLOCK_SCRIPT, 1, resource, val])
      rescue
        # Nothing to do, unlocking is just a best-effort attempt.
      end
    end

    def try_lock_instances(resource, ttl)
      @retry_count.times do
        lock_info = lock_instances(resource, ttl)
        return lock_info if lock_info

        # Wait a random delay before retrying
        sleep(rand(@retry_delay).to_f / 1000)
      end

      false
    end

    def lock_instances(resource, ttl)
      value = SecureRandom.uuid

      locked, time_elapsed = timed do
        @servers.select { |s| s.lock(resource, value, ttl) }.size
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
      drift = (ttl * CLOCK_DRIFT_FACTOR).to_i + 2
    end

    def timed
      start_time = (Time.now.to_f * 1000).to_i
      [yield, (Time.now.to_f * 1000).to_i - start_time]
    end
  end
end
