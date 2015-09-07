require 'redis'
require 'securerandom'
require 'set'

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
      @heartbeats = Set.new
      servers.each do |s|
        Thread.new do
          loop do
            @heartbeats.each { |resource| s.heartbeat resource }
            sleep 1
          end
        end
      end
    end

    def testing=(mode)
      @testing_mode = mode
    end

    # Locks a resource for a given time.
    # Params:
    # +resource+:: the resource (or key) string to be locked.
    # +ttl+:: The time-to-live in ms for the lock.
    # +block+:: an optional block that automatically unlocks the lock.
    def lock(resource, ttl, &block)
      if @testing_mode == :bypass
        lock_info = {
          validity: ttl,
          resource: resource,
          value: SecureRandom.uuid
        }
      elsif @testing_mode == :fail
        lock_info = false
      else
        lock_info = try_lock_instances(resource, ttl)
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
      return if @testing_mode == :bypass
      @heartbeats.delete lock_info[:resource]
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

      def initialize(connection)
        if connection.respond_to?(:client)
          @redis = connection
        else
          @redis  = Redis.new(connection)
        end

        @unlock_script_sha = @redis.script(:load, UNLOCK_SCRIPT)
      end

      def lock(resource, val, ttl)
        if @redis.exists(resource) and not heartbeat?(resource)
          sleep 1                   unless heartbeat?(resource) # one last chance
          @redis.del resource       unless heartbeat?(resource)
        end
        @redis.set(resource, val, nx: true, px: ttl)
      end

      def unlock(resource, val)
        @redis.evalsha(@unlock_script_sha, keys: [resource], argv: [val])
      rescue
        # Nothing to do, unlocking is just a best-effort attempt.
      end

      def heartbeat(resource)
        @redis.set(heartbeat_key(resource), nil, px: 2000)
      end

      private

      def heartbeat?(resource)
        @redis.exists heartbeat_key(resource)
      end

      def heartbeat_key(resource)
        "heartbeat/#{resource}"
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
        start_heartbeat resource
        { validity: validity, resource: resource, value: value }
      else
        @servers.each { |s| s.unlock(resource, value) }
        false
      end
    end

    def start_heartbeat(resource)
      @servers.each { |s| s.heartbeat resource }
      @heartbeats << resource
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
