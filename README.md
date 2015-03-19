[![Build Status](https://travis-ci.org/leandromoreira/redlock-rb.svg?branch=master)](https://travis-ci.org/leandromoreira/redlock-rb)
[![Coverage Status](https://coveralls.io/repos/leandromoreira/redlock-rb/badge.svg?branch=master)](https://coveralls.io/r/leandromoreira/redlock-rb?branch=master)

# Redlock - A ruby distributed lock using redis.

> Distributed locks are a very useful primitive in many environments where different processes require to operate  with shared resources in a mutually exclusive way.
>
> There are a number of libraries and blog posts describing how to implement a DLM (Distributed Lock Manager) with Redis, but every library uses a different approach, and many use a simple approach with lower guarantees compared to what can be achieved with slightly more complex designs.

This is an implementation of a proposed [distributed lock algorithm with Redis](http://redis.io/topics/distlock). It started as a fork from [antirez implementation.](https://github.com/antirez/redlock-rb)

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

## Run tests

Make sure you have at least 1 redis instances up.

   $ rspec

## Contributing

1. [Fork it](https://github.com/leandromoreira/redlock-rb/fork)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request
