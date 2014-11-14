# Redlock - A ruby distributed lock using redis.

Distributed locks are a very useful primitive in many environments where different processes require to operate with shared resources in a mutually exclusive way.

There are a number of libraries and blog posts describing how to implement a DLM (Distributed Lock Manager) with Redis, but every library uses a different approach, and many use a simple approach with lower guarantees compared to what can be achieved with slightly more complex designs.

This lib is an attempt to provide an implementation to a proposed distributed locks with Redis. Totally inspired by: [Redis topic distlock](http://redis.io/topics/distlock)

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

[RubyDoc](http://www.rubydoc.info/github/leandromoreira/redlock-rb/)

## Usage example

```ruby
  # Locking
  lock_manager = Redlock::Client.new([ "redis://127.0.0.1:7777", "redis://127.0.0.1:7778", "redis://127.0.0.1:7779" ])
  first_try_lock_info = lock_manager.lock("resource_key", 2000)
  second_try_lock_info = lock_manager.lock("resource_key", 2000)

  # it prints lock info
  p first_try_lock_info
  # it prints false
  p second_try_lock_info

  # Unlocking
  lock_manager.unlock(first_try_lock_info)
  second_try_lock_info = lock_manager.lock("resource_key", 2000)

  # now it prints lock info
  p second_try_lock_info
```

## Run tests

Make sure you have at least 3 redis instances `redis-server --port 777[7-9]`

   $ rspec

## Contributing

1. [Fork it](https://github.com/leandromoreira/redlock-rb/fork)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request
