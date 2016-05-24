[![Stories in Ready](https://badge.waffle.io/leandromoreira/redlock-rb.png?label=ready&title=Ready)](https://waffle.io/leandromoreira/redlock-rb)
[![Build Status](https://travis-ci.org/leandromoreira/redlock-rb.svg?branch=master)](https://travis-ci.org/leandromoreira/redlock-rb)
[![Coverage Status](https://coveralls.io/repos/leandromoreira/redlock-rb/badge.svg?branch=master)](https://coveralls.io/r/leandromoreira/redlock-rb?branch=master)
[![Code Climate](https://codeclimate.com/github/leandromoreira/redlock-rb/badges/gpa.svg)](https://codeclimate.com/github/leandromoreira/redlock-rb)
[![Dependency Status](https://gemnasium.com/leandromoreira/redlock-rb.svg)](https://gemnasium.com/leandromoreira/redlock-rb)
[![Gem Version](https://badge.fury.io/rb/redlock.svg)](http://badge.fury.io/rb/redlock)
[![security](https://hakiri.io/github/leandromoreira/redlock-rb/master.svg)](https://hakiri.io/github/leandromoreira/redlock-rb/master)
[![Inline docs](http://inch-ci.org/github/leandromoreira/redlock-rb.svg?branch=master)](http://inch-ci.org/github/leandromoreira/redlock-rb)
[![Join the chat at https://gitter.im/leandromoreira/redlock-rb](https://badges.gitter.im/Join%20Chat.svg)](https://gitter.im/leandromoreira/redlock-rb?utm_source=badge&utm_medium=badge&utm_campaign=pr-badge&utm_content=badge)

[![Codeship](https://codeship.com/projects/901ff180-c1ad-0132-1a88-3eb2295b72b3/status?branch=master)](https://codeship.com/projects/901ff180-c1ad-0132-1a88-3eb2295b72b3/status?branch=master)


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

```ruby
  # Locking
  lock_manager = Redlock::Client.new([ "redis://127.0.0.1:7777", "redis://127.0.0.1:7778", "redis://127.0.0.1:7779" ])
  first_try_lock_info = lock_manager.lock("resource_key", 2000)
  second_try_lock_info = lock_manager.lock("resource_key", 2000)

  # it prints lock info {validity: 1987, resource: "resource_key", value: "generated_uuid4"}
  p first_try_lock_info
  # it prints false
  p second_try_lock_info

  # Unlocking
  lock_manager.unlock(first_try_lock_info)
  second_try_lock_info = lock_manager.lock("resource_key", 2000)

  # now it prints lock info
  p second_try_lock_info
```

Redlock works seamlessly with [redis sentinel](http://redis.io/topics/sentinel), which is supported in redis 3.2+. It also allows clients to set any other arbitrary options on the Redis connection, e.g. password, driver, and more.

```ruby
servers = [ 'redis://localhost:6379', Redis.new(:url => 'redis://someotherhost:6379') ]
redlock = Redlock::Client.new(servers)
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

There's also a bang version that only executes the block if the lock is successfully acquired, returning the block's value as a result, or raising an exception otherwise:

```ruby
begin
  block_result = lock_manager.lock!("resource_key", 2000) do
    # critical code
  end
rescue Redlock::LockError
  # error handling
end
```

To extend the life of the lock:

```ruby
begin
  block_result = lock_manager.lock!("resource_key", 2000) do |lock_info|
    # critical code
    lock_manager.lock("resource key", 3000, extend: lock_info)
    # more critical code
  end
rescue Redlock::LockError
  # error handling
end
```

The above code will also acquire the lock if the previous lock has expired and the lock is currently free. Keep in mind that this means the lock could have been acquired by someone else in the meantime. To only extend the life of the lock if currently locked by yourself, use `extend_life` parameter:

```ruby
begin
  block_result = lock_manager.lock!("resource_key", 2000) do |lock_info|
    # critical code
    lock_manager.lock("resource key", 3000, extend: lock_info, extend_life: true)
    # more critical code, only if lock was still hold
  end
rescue Redlock::LockError
  # error handling
end
```


## Run tests

Make sure you have at least 1 redis instances up.

    $ rspec

## Disclaimer

This code implements an algorithm which is currently a proposal, it was not formally analyzed. Make sure to understand how it works before using it in your production environments. You can see discussion about this approach at [reddit](http://www.reddit.com/r/programming/comments/2nt0nq/distributed_lock_using_redis_implemented_in_ruby/).

## Contributing

1. [Fork it](https://github.com/leandromoreira/redlock-rb/fork)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request
