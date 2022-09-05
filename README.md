[![Build Status](https://github.com/leandromoreira/redlock-rb/actions/workflows/ci.yml/badge.svg)](https://github.com/leandromoreira/redlock-rb/actions/workflows/ci.yml)
[![Coverage Status](https://coveralls.io/repos/leandromoreira/redlock-rb/badge.svg?branch=master)](https://coveralls.io/r/leandromoreira/redlock-rb?branch=master)
[![Code Climate](https://codeclimate.com/github/leandromoreira/redlock-rb/badges/gpa.svg)](https://codeclimate.com/github/leandromoreira/redlock-rb)
[![Gem Version](https://badge.fury.io/rb/redlock.svg)](http://badge.fury.io/rb/redlock)
[![Inline docs](http://inch-ci.org/github/leandromoreira/redlock-rb.svg?branch=master)](http://inch-ci.org/github/leandromoreira/redlock-rb)


# Redlock - A ruby distributed lock using redis.

> Distributed locks are a very useful primitive in many environments where different processes require to operate  with shared resources in a mutually exclusive way.
>
> There are a number of libraries and blog posts describing how to implement a DLM (Distributed Lock Manager) with Redis, but every library uses a different approach, and many use a simple approach with lower guarantees compared to what can be achieved with slightly more complex designs.

This is an implementation of a proposed [distributed lock algorithm with Redis](http://redis.io/topics/distlock). It started as a fork from [antirez implementation.](https://github.com/antirez/redlock-rb)

## Compatibility

Redlock works with Redis versions 2.6 or later.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'redlock'
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install redlock

## Documentation

[RubyDoc](http://www.rubydoc.info/gems/redlock/frames)

## Usage example

### Acquiring a lock

NOTE: All expiration durations are in milliseconds.
```ruby
  # Locking
  lock_manager = Redlock::Client.new([ "redis://127.0.0.1:7777", "redis://127.0.0.1:7778", "redis://127.0.0.1:7779" ])
  first_try_lock_info = lock_manager.lock("resource_key", 2000)
  second_try_lock_info = lock_manager.lock("resource_key", 2000)

  p first_try_lock_info
  # => {validity: 1987, resource: "resource_key", value: "generated_uuid4"}

  p second_try_lock_info
  # => false

  # Unlocking
  lock_manager.unlock(first_try_lock_info)

  second_try_lock_info = lock_manager.lock("resource_key", 2000)

  p second_try_lock_info
  # => {validity: 1962, resource: "resource_key", value: "generated_uuid5"}
```

There's also a block version that automatically unlocks the lock:

```ruby
lock_manager.lock("resource_key", 2000) do |locked|
  if locked
    # critical code
  else
    # error handling
  end
end
```

There's also a bang version that only executes the block if the lock is successfully acquired, returning the block's value as a result, or raising an exception otherwise. Passing a block is mandatory.

```ruby
begin
  block_result = lock_manager.lock!("resource_key", 2000) do
    # critical code
  end
rescue Redlock::LockError
  # error handling
end
```

### Extending a lock

To extend the life of the lock:

```ruby
begin
  lock_info = lock_manager.lock("resource_key", 2000)
  while lock_info
    # Critical code

    # Time up and more work to do? Extend the lock.
    lock_info = lock_manager.lock("resource key", 3000, extend: lock_info)
  end
rescue Redlock::LockError
  # error handling
end
```

The above code will also acquire the lock if the previous lock has expired and the lock is currently free. Keep in mind that this means the lock could have been acquired and released by someone else in the meantime. To only extend the life of the lock if currently locked by yourself, use the `extend_only_if_locked` parameter:

```ruby
lock_manager.lock("resource key", 3000, extend: lock_info, extend_only_if_locked: true)
```

### Querying lock status

You can check if a resource is locked:

```ruby
resource = "resource_key"
lock_info = lock_manager.lock(resource, 2000)
lock_manager.locked?(resource)
#=> true

lock_manager.unlock(lock_info)
lock_manager.locked?(resource)
#=> false
```

Any caller can call the above method to query the status. If you hold a lock and would like to check if it is valid, you can use the `valid_lock?` method:

```ruby
lock_info = lock_manager.lock("resource_key", 2000)
lock_manager.valid_lock?(lock_info)
#=> true

lock_manager.unlock(lock_info)
lock_manager.valid_lock?(lock_info)
#=> false
```

The above methods **are not safe if you are using this to time critical code**, since they return true if the lock has not expired, even if there's only (for example) 1ms left on the lock. If you want to safely time the lock validity, you can use the `get_remaining_ttl_for_lock` and `get_remaining_ttl_for_resource` methods.

Use `get_remaining_ttl_for_lock` if you hold a lock and want to check the TTL specifically for your lock:
```ruby
resource = "resource_key"
lock_info = lock_manager.lock(resource, 2000)
sleep 1

lock_manager.get_remaining_ttl_for_lock(lock_info)
#=> 986

lock_manager.unlock(lock_info)
lock_manager.get_remaining_ttl_for_lock(lock_info)
#=> nil 
```

Use `get_remaining_ttl_for_resource` if you do not hold a lock, but want to know the remaining TTL on a locked resource:
```ruby
# Some part of the code
resource = "resource_key"
lock_info = lock_manager.lock(resource, 2000)

# Some other part of the code
lock_manager.locked?(resource)
#=> true
lock_manager.get_remaining_ttl_for_resource(resource)
#=> 1975 

# Sometime later
lock_manager.locked?(resource)
#=> false
lock_manager.get_remaining_ttl_for_resource(resource)
#=> nil 
```

## Redis client configuration

`Redlock::Client` expects URLs or Redis objects on initialization. Redis objects should be used for configuring the connection in more detail, i.e. setting username and password.

```ruby
servers = [ 'redis://localhost:6379', Redis.new(:url => 'redis://someotherhost:6379') ]
redlock = Redlock::Client.new(servers)
```

Redlock works seamlessly with [redis sentinel](http://redis.io/topics/sentinel), which is supported in redis 3.2+.

## Redlock configuration

It's possible to customize the retry logic providing the following options:

```ruby
  lock_manager = Redlock::Client.new(
                  servers, {
                  retry_count:   3,
                  retry_delay:   200, # milliseconds
                  retry_jitter:  50,  # milliseconds
                  redis_timeout: 0.1  # seconds
                 })
```

It is possible to associate `:retry_delay` option with `Proc` object. It will be called every time, with attempt number
as argument, to get delay time value before next retry.

```ruby
retry_delay = proc { |attempt_number| 200 * attempt_number ** 2 } # delay of 200ms for 1st retry, 800ms for 2nd retry, etc.
lock_manager = Redlock::Client.new(servers, retry_delay: retry_delay)
```

For more information you can check [documentation](http://www.rubydoc.info/gems/redlock/Redlock%2FClient:initialize).

## Run tests

Make sure you have [docker installed](https://docs.docker.com/engine/installation/).

    $ make

## Disclaimer

This code implements an algorithm which is currently a proposal, it was not formally analyzed. Make sure to understand how it works before using it in your production environments. You can see discussion about this approach at [reddit](http://www.reddit.com/r/programming/comments/2nt0nq/distributed_lock_using_redis_implemented_in_ruby/) and also the [Antirez answers](http://antirez.com/news/101) for some critics.

## Contributing

1. [Fork it](https://github.com/leandromoreira/redlock-rb/fork)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request
