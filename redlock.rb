require 'redis'

class Redlock
    DefaultRetryCount=3
    DefaultRetryDelay=200
    ClockDriftFactor = 0.01
    UnlockScript='
    if redis.call("get",KEYS[1]) == ARGV[1] then
        return redis.call("del",KEYS[1])
    else
        return 0
    end'

    def initialize(*server_urls)
        @servers = []
        server_urls.each{|url|
            @servers << Redis.new(:url => url)
        }
        @quorum = server_urls.length / 2 + 1
        @retry_count = DefaultRetryCount
        @retry_delay = DefaultRetryDelay
        @urandom = File.new("/dev/urandom")
    end

    def set_retry(count,delay)
        @retry_count = count
        @retry_delay = delay
    end

    def lock_instance(redis,resource,val,ttl)
        begin
            return redis.client.call([:set,resource,val,:nx,:px,ttl])
        rescue
            return false
        end
    end

    def unlock_instance(redis,resource,val)
        begin
            redis.client.call([:eval,UnlockScript,1,resource,val])
        rescue
            # Nothing to do, unlocking is just a best-effort attempt.
        end
    end

    def get_unique_lock_id
        val = ""
        bytes = @urandom.read(20)
        bytes.each_byte{|b|
            val << b.to_s(32)
        }
        val 
    end

    def lock(resource,ttl)
        val = get_unique_lock_id
        @retry_count.times {
            n = 0
            start_time = (Time.now.to_f*1000).to_i
            @servers.each{|s|
                n += 1 if lock_instance(s,resource,val,ttl)
            }
            # Add 2 milliseconds to the drift to account for Redis expires
            # precision, which is 1 milliescond, plus 1 millisecond min drift 
            # for small TTLs.
            drift = (ttl*ClockDriftFactor).to_i + 2
            validity_time = ttl-((Time.now.to_f*1000).to_i - start_time)-drift 
            if n >= @quorum && validity_time > 0
                return {
                    :validity => validity_time,
                    :resource => resource,
                    :val => val
                }
            else
                @servers.each{|s|
                    unlock_instance(s,resource,val)
                }
            end
            # Wait a random delay before to retry
            sleep(rand(@retry_delay).to_f/1000)
        }
        return false
    end

    def unlock(lock)
        @servers.each{|s|
            unlock_instance(s,lock[:resource],lock[:val])
        }
    end
end
