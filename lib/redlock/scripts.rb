require 'digest'

module Redlock
  module Scripts
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
      if (redis.call("exists", KEYS[1]) == 0 and ARGV[3] == "yes") or redis.call("get", KEYS[1]) == ARGV[1] then
        return redis.call("set", KEYS[1], ARGV[1], "PX", ARGV[2])
      end
    eos

    PTTL_SCRIPT = <<-eos
      return { redis.call("get", KEYS[1]), redis.call("pttl", KEYS[1]) }
    eos

    # We do not want to load the scripts on every Redlock::Client initialization.
    # Hence, we rely on Redis handing out SHA1 hashes of the cached scripts and
    # pre-calculate them instead of loading the scripts unconditionally. If the scripts
    # have not been cached on Redis, `recover_from_script_flush` has our backs.
    UNLOCK_SCRIPT_SHA = Digest::SHA1.hexdigest(UNLOCK_SCRIPT)
    LOCK_SCRIPT_SHA   = Digest::SHA1.hexdigest(LOCK_SCRIPT)
    PTTL_SCRIPT_SHA   = Digest::SHA1.hexdigest(PTTL_SCRIPT)
  end
end
