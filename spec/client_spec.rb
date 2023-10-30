require 'spec_helper'
require 'securerandom'
require 'connection_pool'

RSpec.describe Redlock::Client do
  # It is recommended to have at least 3 servers in production
  let(:lock_manager_opts) { { retry_count: 3 } }
  let(:redis_urls_or_clients) {
    urls = Redlock::Client::DEFAULT_REDIS_URLS
    if rand(0..1).zero?
      RSpec.configuration.reporter.message "variant: client urls"
      urls
    else
      RSpec.configuration.reporter.message "variant: client objects"
      urls.map {|url|
        ConnectionPool.new { RedisClient.new(url: url) }
      }
    end
  }
  let(:lock_manager) {
    Redlock::Client.new(redis_urls_or_clients, lock_manager_opts)
  }
  let(:redis_client) { RedisClient.new(url: "redis://#{redis1_host}:#{redis1_port}") }
  let(:resource_key) { SecureRandom.hex(3)  }
  let(:ttl) { 1000 }
  let(:redis1_host) { ENV["REDIS1_HOST"] || "localhost" }
  let(:redis1_port) { ENV["REDIS1_PORT"] || "6379" }
  let(:redis2_host) { ENV["REDIS2_HOST"] || "127.0.0.1" }
  let(:redis2_port) { ENV["REDIS2_PORT"] || "6379" }
  let(:redis3_host) { ENV["REDIS3_HOST"] || "127.0.0.1" }
  let(:redis3_port) { ENV["REDIS3_PORT"] || "6379" }
  let(:unreachable_redis) {
    RedisClient.new(url: 'redis://localhost:46864')
  }

  describe 'initialize' do
    it 'accepts both redis URLs and Redis objects' do
      servers = [ "redis://#{redis1_host}:#{redis1_port}", RedisClient.new(url: "redis://#{redis2_host}:#{redis2_port}") ]
      redlock = Redlock::Client.new(servers)

      redlock_servers = redlock.instance_variable_get(:@servers).map do |s|
        s.instance_variable_get(:@redis).config.host
      end

      expect(redlock_servers).to match_array([redis1_host, redis2_host])
    end

    it 'accepts ConnectionPool objects' do
      pool = ConnectionPool.new { RedisClient.new(url: "redis://#{redis1_host}:#{redis1_port}") }
      _redlock = Redlock::Client.new([pool])

      lock_info = lock_manager.lock(resource_key, ttl)
      expect(lock_info).to be_a(Hash)
      expect(resource_key).to_not be_lockable(lock_manager, ttl)
      lock_manager.unlock(lock_info)
    end

    it 'accepts Configuration hashes' do
      config = { url: "redis://#{redis1_host}:#{redis1_port}" }
      _redlock = Redlock::Client.new([config])

      lock_info = lock_manager.lock(resource_key, ttl)
      expect(lock_info).to be_a(Hash)
      expect(resource_key).to_not be_lockable(lock_manager, ttl)
      lock_manager.unlock(lock_info)
    end

    it 'does not load scripts' do
      redis_client.call('SCRIPT', 'FLUSH')

      pool = ConnectionPool.new { RedisClient.new(url: "redis://#{redis1_host}:#{redis1_port}") }
      _redlock = Redlock::Client.new([pool])

      raw_info = redis_client.call('INFO')
      number_of_cached_scripts = raw_info[/number_of_cached_scripts\:\d+/].split(':').last

      expect(number_of_cached_scripts).to eq("0")
    end
  end

  describe 'lock' do
    context 'when lock is available' do
      after(:each) { lock_manager.unlock(@lock_info) if @lock_info }

      context 'when redis connection error occurs' do
        let(:servers_with_quorum) {
          [
            "redis://#{redis1_host}:#{redis1_port}",
            "redis://#{redis2_host}:#{redis2_port}",
            unreachable_redis
          ]
        }

        let(:servers_without_quorum) {
          [
            "redis://#{redis1_host}:#{redis1_port}",
            unreachable_redis,
            unreachable_redis
          ]
        }

        it 'locks if majority of redis instances are available' do
          redlock = Redlock::Client.new(servers_with_quorum)

          expect(redlock.lock(resource_key, ttl)).to be_truthy
        end

        it 'fails to acquire a lock if majority of Redis instances are not available' do
          redlock = Redlock::Client.new(servers_without_quorum)

          expected_msg = <<~MSG
            failed to acquire lock on 'Too many Redis errors prevented lock acquisition:
            RedisClient::CannotConnectError: Connection refused - connect(2) for 127.0.0.1:46864
            RedisClient::CannotConnectError: Connection refused - connect(2) for 127.0.0.1:46864'
          MSG

          expect {
            redlock.lock(resource_key, ttl)
          }.to raise_error do |error|
            expect(error).to be_a(Redlock::LockAcquisitionError)
            expect(error.message).to eq(expected_msg.chomp)
            expect(error.errors.size).to eq(2)
          end
        end
      end

      it 'locks' do
        @lock_info = lock_manager.lock(resource_key, ttl)

        expect(resource_key).to_not be_lockable(lock_manager, ttl)
      end

      it 'returns lock information' do
        @lock_info = lock_manager.lock(resource_key, ttl)

        expect(@lock_info).to be_lock_info_for(resource_key)
      end

      it 'interprets lock time as milliseconds' do
        ttl = 20000
        @lock_info = lock_manager.lock(resource_key, ttl)
        expect(redis_client.call('PTTL', resource_key)).to be_within(200).of(ttl)
      end

      it 'can extend its own lock' do
        my_lock_info = lock_manager.lock(resource_key, ttl)
        @lock_info = lock_manager.lock(resource_key, ttl, extend: my_lock_info)
        expect(@lock_info).to be_lock_info_for(resource_key)
        expect(@lock_info[:value]).to eq(my_lock_info[:value])
      end

      context 'when extend param is nil' do
        it 'defaults to creating a new lock' do
          @lock_info = lock_manager.lock(resource_key, ttl, extend: nil)
          expect(@lock_info).to be_lock_info_for(resource_key)
          expect(@lock_info[:value]).to be
        end
      end

      context 'when extend_only_if_locked flag is given' do
        it 'does not extend a non-existent lock' do
          @lock_info = lock_manager.lock(resource_key, ttl, extend: {value: 'hello world'}, extend_only_if_locked: true)
          expect(@lock_info).to eq(false)
        end
      end

      it '(when extending) resets the TTL, rather than adding extra time to it' do
        ttl = 20000
        lock_info = lock_manager.lock(resource_key, ttl)
        expect(resource_key).to_not be_lockable(lock_manager, ttl)

        lock_info = lock_manager.lock(resource_key, ttl, extend: lock_info, extend_only_if_locked: true)
        expect(lock_info).not_to be_nil
        expect(redis_client.call('PTTL', resource_key)).to be_within(200).of(ttl)
      end

      context 'when extend_only_if_locked flag is not given' do
        it "sets the given value when trying to extend a non-existent lock" do
          @lock_info = lock_manager.lock(resource_key, ttl, extend: {value: 'hello world'}, extend_only_if_locked: false)
          expect(@lock_info).to be_lock_info_for(resource_key)
          expect(@lock_info[:value]).to eq('hello world') # really we should test what's in redis
        end
      end

      it "doesn't extend somebody else's lock" do
        @lock_info = lock_manager.lock(resource_key, ttl)
        second_attempt = lock_manager.lock(resource_key, ttl)
        expect(second_attempt).to eq(false)
      end

      context 'when extend_life flag is given' do
        it 'treats it as extend_only_if_locked but warns it is deprecated' do
          ttl = 20_000
          lock_info = lock_manager.lock(resource_key, ttl)
          expect(resource_key).to_not be_lockable(lock_manager, ttl)
          expect(lock_manager).to receive(:warn).with(/DEPRECATION WARNING: The `extend_life`/)
          lock_info = lock_manager.lock(resource_key, ttl, extend: lock_info, extend_life: true)
          expect(lock_info).not_to be_nil
        end
      end

      context 'when extend_only_if_life flag is given' do
        it 'treats it as extend_only_if_locked but warns it is deprecated' do
          ttl = 20_000
          lock_info = lock_manager.lock(resource_key, ttl)
          expect(resource_key).to_not be_lockable(lock_manager, ttl)
          expect(lock_manager).to receive(:warn).with(/DEPRECATION WARNING: The `extend_only_if_life`/)
          lock_info = lock_manager.lock(resource_key, ttl, extend: lock_info, extend_only_if_life: true)
          expect(lock_info).not_to be_nil
        end
      end
    end

    context 'when lock is not available' do
      before { @another_lock_info = lock_manager.lock(resource_key, ttl) }
      after { lock_manager.unlock(@another_lock_info) }

      it 'returns false' do
        lock_info = lock_manager.lock(resource_key, ttl)

        expect(lock_info).to eql(false)
      end

      it "can't extend somebody else's lock" do
        yet_another_lock_info = @another_lock_info.merge value: 'gibberish'
        lock_info = lock_manager.lock(resource_key, ttl, extend: yet_another_lock_info)
        expect(lock_info).to eql(false)
      end

      it 'tries up to \'retry_count\' + 1 times' do
        expect(lock_manager).to receive(:lock_instances).exactly(
          lock_manager_opts[:retry_count] + 1).times.and_return(false)
        lock_manager.lock(resource_key, ttl)
      end

      it 'sleeps in between retries' do
        expect(lock_manager).to receive(:sleep).exactly(lock_manager_opts[:retry_count]).times
        lock_manager.lock(resource_key, ttl)
      end

      it 'sleeps at least the specified retry_delay in milliseconds' do
        expected_minimum = described_class::DEFAULT_RETRY_DELAY
        expect(lock_manager).to receive(:sleep) do |sleep|
          expect(sleep).to satisfy { |value| value >= expected_minimum / 1000.to_f }
        end.at_least(:once)
        lock_manager.lock(resource_key, ttl)
      end

      it 'sleeps a maximum of retry_delay + retry_jitter in milliseconds' do
        expected_maximum = described_class::DEFAULT_RETRY_DELAY + described_class::DEFAULT_RETRY_JITTER
        expect(lock_manager).to receive(:sleep) do |sleep|
          expect(sleep).to satisfy { |value| value < expected_maximum / 1000.to_f }
        end.at_least(:once)
        lock_manager.lock(resource_key, ttl)
      end

      it 'accepts retry_delay as proc' do
        retry_delay = proc do |attempt_number|
          expect(attempt_number).to eq(1)
          2000
        end

        lock_manager = Redlock::Client.new(redis_urls_or_clients, retry_count: 1, retry_delay: retry_delay)
        another_lock_info = lock_manager.lock(resource_key, ttl)

        expect(lock_manager).to receive(:sleep) do |sleep|
          expect(sleep * 1000).to be_within(described_class::DEFAULT_RETRY_JITTER).of(2000)
        end.exactly(:once)
        lock_manager.lock(resource_key, ttl)
        lock_manager.unlock(another_lock_info)
      end

      context 'when retry_count is given' do
        it 'prioritizes the retry_count in option and tries up to \'retry_count\' + 1 times' do
          retry_count = 1
          expect(retry_count).not_to eq(lock_manager_opts[:retry_count])
          expect(lock_manager).to receive(:lock_instances).exactly(retry_count + 1).times.and_return(false)
          lock_manager.lock(resource_key, ttl, retry_count: retry_count)
        end
      end

      context 'when retry_delay is given' do
        it 'prioritizes the retry_delay in option and sleeps at least the specified retry_delay in milliseconds' do
          retry_delay = 300
          expect(retry_delay > described_class::DEFAULT_RETRY_DELAY).to eq(true)
          expected_minimum = retry_delay

          expect(lock_manager).to receive(:sleep) do |sleep|
            expect(sleep).to satisfy { |value| value >= expected_minimum / 1000.to_f }
          end.at_least(:once)
          lock_manager.lock(resource_key, ttl, retry_delay: retry_delay)
        end
      end

      context 'when retry_jitter is given' do
        it 'prioritizes the retry_jitter in option and sleeps a maximum of retry_delay + retry_jitter in milliseconds' do
          retry_jitter = 60
          expect(retry_jitter > described_class::DEFAULT_RETRY_JITTER).to eq(true)

          expected_maximum = described_class::DEFAULT_RETRY_DELAY + retry_jitter
          expect(lock_manager).to receive(:sleep) do |sleep|
            expect(sleep).to satisfy { |value| value < expected_maximum / 1000.to_f }
          end.at_least(:once)
          lock_manager.lock(resource_key, ttl, retry_jitter: retry_jitter)
        end
      end
    end

    context 'when a server goes away' do
      it 'raises an error on connection issues' do
        # Set lock manager to a (hopefully) non-existent Redis URL to test error
        redis_instance = lock_manager.instance_variable_get(:@servers).first
        redis_instance.instance_variable_set(:@redis, unreachable_redis)

        expect {
          lock_manager.lock(resource_key, ttl)
        }.to raise_error(Redlock::LockAcquisitionError) do |e|
          expect(e.errors[0]).to be_a(RedisClient::CannotConnectError)
          expect(e.errors.count).to eq 1
        end
      end
    end

    context 'when a server comes back' do
      it 'recovers from connection issues' do
        # Same as above.
        redis_instance = lock_manager.instance_variable_get(:@servers).first
        old_redis = redis_instance.instance_variable_get(:@redis)
        redis_instance.instance_variable_set(:@redis, unreachable_redis)
        expect {
          lock_manager.lock(resource_key, ttl)
        }.to raise_error(Redlock::LockAcquisitionError) do |e|
          expect(e.errors[0]).to be_a(RedisClient::CannotConnectError)
          expect(e.errors.count).to eq 1
        end
        redis_instance.instance_variable_set(:@redis, old_redis)
        expect(lock_manager.lock(resource_key, ttl)).to be_truthy
      end
    end

    context 'when script cache has been flushed' do
      before(:each) do
        @manipulated_instance = lock_manager.instance_variable_get(:@servers).first
        @manipulated_instance.instance_variable_get(:@redis).with { |conn|
          conn.call('SCRIPT', 'FLUSH')
        }
      end

      it 'does not raise a RedisClient::CommandError: NOSCRIPT error' do
        expect {
          lock_manager.lock(resource_key, ttl)
        }.to_not raise_error
      end

      it 'tries to load the scripts to cache again' do
        expect(@manipulated_instance).to receive(:load_scripts).and_call_original
        lock_manager.lock(resource_key, ttl)
      end

      context 'when the script re-loading fails' do
        it 'does not try to to load the scripts to cache again twice' do
          # This time we do not pass it through to Redis, in order to simulate a passing
          # call to LOAD SCRIPT followed by another NOSCRIPT error. Imagine someone
          # repeatedly calling SCRIPT FLUSH on our Redis instance.
          expect(@manipulated_instance).to receive(:load_scripts).exactly(8).times

          expect {
            lock_manager.lock(resource_key, ttl)
          }.to raise_error(Redlock::LockAcquisitionError) do |e|
            expect(e.errors[0]).to be_a(RedisClient::CommandError)
            expect(e.errors[0].message).to match(/NOSCRIPT/)
            expect(e.errors.count).to eq 1
          end
        end
      end

      context 'when the script re-loading succeeds' do
        it 'locks' do
          expect(lock_manager.lock(resource_key, ttl)).to be_lock_info_for(resource_key)
        end
      end
    end

    describe 'block syntax' do
      context 'when lock is available' do
        it 'locks' do
          lock_manager.lock(resource_key, ttl) do |_|
            expect(resource_key).to_not be_lockable(lock_manager, ttl)
          end
        end

        it 'passes lock information as block argument' do
          lock_manager.lock(resource_key, ttl) do |lock_info|
            expect(lock_info).to be_lock_info_for(resource_key)
          end
        end

        it 'returns true' do
          rv = lock_manager.lock(resource_key, ttl) {}
          expect(rv).to eql(true)
        end

        it 'automatically unlocks' do
          lock_manager.lock(resource_key, ttl) {}
          expect(resource_key).to be_lockable(lock_manager, ttl)
        end

        it 'automatically unlocks when block raises exception' do
          lock_manager.lock(resource_key, ttl) { fail } rescue nil
          expect(resource_key).to be_lockable(lock_manager, ttl)
        end
      end

      context 'when lock is not available' do
        before { @another_lock_info = lock_manager.lock(resource_key, ttl) }
        after { lock_manager.unlock(@another_lock_info) }

        it 'passes false as block argument' do
          lock_manager.lock(resource_key, ttl) do |lock_info|
            expect(lock_info).to eql(false)
          end
        end

        it 'returns false' do
          rv = lock_manager.lock(resource_key, ttl) {}
          expect(rv).to eql(false)
        end
      end
    end
  end

  describe 'unlock' do
    before { @lock_info = lock_manager.lock(resource_key, ttl) }

    it 'unlocks' do
      expect(resource_key).to_not be_lockable(lock_manager, ttl)

      lock_manager.unlock(@lock_info)

      expect(resource_key).to be_lockable(lock_manager, ttl)
    end
  end

  describe 'lock!' do
    context 'when lock is available' do
      it 'locks' do
        lock_manager.lock!(resource_key, ttl) do
          expect(resource_key).to_not be_lockable(lock_manager, ttl)
        end
      end

      it "returns the received block's return value" do
        rv = lock_manager.lock!(resource_key, ttl) { :success }
        expect(rv).to eql(:success)
      end

      it 'automatically unlocks' do
        lock_manager.lock!(resource_key, ttl) {}
        expect(resource_key).to be_lockable(lock_manager, ttl)
      end

      it 'automatically unlocks when block raises exception' do
        lock_manager.lock!(resource_key, ttl) { fail } rescue nil
        expect(resource_key).to be_lockable(lock_manager, ttl)
      end

      it 'passes the extension parameter' do
        my_lock_info = lock_manager.lock(resource_key, ttl)
        expect{ lock_manager.lock!(resource_key, ttl, extend: my_lock_info){} }.to_not raise_error
      end
    end

    context 'when lock is not available' do
      before { @another_lock_info = lock_manager.lock(resource_key, ttl) }
      after { lock_manager.unlock(@another_lock_info) }

      it 'raises a LockError' do
        expect { lock_manager.lock!(resource_key, ttl) {} }.to raise_error(
          Redlock::LockError, "failed to acquire lock on '#{resource_key}'"
        )
      end

      it 'does not execute the block' do
        expect do
          begin
            lock_manager.lock!(resource_key, ttl) { fail }
          rescue Redlock::LockError
          end
        end.to_not raise_error
      end
    end
  end

  describe 'get_remaining_ttl_for_resource' do
    context 'when lock is valid' do
      after(:each) { lock_manager.unlock(@lock_info) if @lock_info }

      it 'gets the remaining ttl of a lock' do
        ttl = 20_000
        @lock_info = lock_manager.lock(resource_key, ttl)
        remaining_ttl = lock_manager.get_remaining_ttl_for_resource(resource_key)
        expect(remaining_ttl).to be_within(300).of(ttl)
      end

      context 'when servers respond with varying ttls' do
        let (:servers) {
          [
            "redis://#{redis1_host}:#{redis1_port}",
            "redis://#{redis2_host}:#{redis2_port}",
            "redis://#{redis3_host}:#{redis3_port}"
          ]
        }
        let (:redlock) { Redlock::Client.new(servers) }
        after(:each) { redlock.unlock(@lock_info) if @lock_info }

        it 'returns the minimum ttl value' do
          ttl = 20_000
          @lock_info = redlock.lock(resource_key, ttl)

          # Mock redis server responses to return different ttls
          returned_ttls = [20_000, 15_000, 10_000]
          redlock.instance_variable_get(:@servers).each_with_index do |server, index|
            allow(server).to(receive(:get_remaining_ttl))
              .with(resource_key)
              .and_return([@lock_info[:value], returned_ttls[index]])
          end

          remaining_ttl = redlock.get_remaining_ttl_for_lock(@lock_info)

          # Assert that the TTL is closest to the closest to the correct value
          expect(remaining_ttl).to be_within(300).of(returned_ttls[1])
        end
      end
    end

    context 'when lock is not valid' do
      it 'returns nil' do
        lock_info = lock_manager.lock(resource_key, ttl)
        lock_manager.unlock(lock_info)
        remaining_ttl = lock_manager.get_remaining_ttl_for_resource(resource_key)
        expect(remaining_ttl).to be_nil
      end
    end

    context 'when server goes away' do
      after(:each) { lock_manager.unlock(@lock_info) if @lock_info }

      it 'does not raise an error on connection issues' do
        @lock_info = lock_manager.lock(resource_key, ttl)

        # Replace redis with unreachable instance
        redis_instance = lock_manager.instance_variable_get(:@servers).first
        _old_redis = redis_instance.instance_variable_get(:@redis)
        redis_instance.instance_variable_set(:@redis, unreachable_redis)

        expect {
          remaining_ttl = lock_manager.get_remaining_ttl_for_resource(resource_key)
          expect(remaining_ttl).to be_nil
        }.to_not raise_error
      end
    end

    context 'when a server comes back' do
      after(:each) { lock_manager.unlock(@lock_info) if @lock_info }

      it 'recovers from connection issues' do
        @lock_info = lock_manager.lock(resource_key, ttl)

        # Replace redis with unreachable instance
        redis_instance = lock_manager.instance_variable_get(:@servers).first
        old_redis = redis_instance.instance_variable_get(:@redis)
        redis_instance.instance_variable_set(:@redis, unreachable_redis)

        expect(lock_manager.get_remaining_ttl_for_resource(resource_key)).to be_nil

        # Restore redis
        redis_instance.instance_variable_set(:@redis, old_redis)
        expect(lock_manager.get_remaining_ttl_for_resource(resource_key)).to be_truthy
      end
    end
  end

  describe 'get_remaining_ttl_for_lock' do
    context 'when lock is valid' do
      it 'gets the remaining ttl of a lock' do
        ttl = 20_000
        lock_info = lock_manager.lock(resource_key, ttl)
        remaining_ttl = lock_manager.get_remaining_ttl_for_lock(lock_info)
        expect(remaining_ttl).to be_within(300).of(ttl)
        lock_manager.unlock(lock_info)
      end
    end

    context 'when lock is not valid' do
      it 'returns nil' do
        lock_info = lock_manager.lock(resource_key, ttl)
        lock_manager.unlock(lock_info)
        remaining_ttl = lock_manager.get_remaining_ttl_for_lock(lock_info)
        expect(remaining_ttl).to be_nil
      end
    end
  end

  describe 'locked?' do
    context 'when lock is available' do
      after(:each) { lock_manager.unlock(@lock_info) if @lock_info }

      it 'returns true' do
        @lock_info = lock_manager.lock(resource_key, ttl)
        expect(lock_manager).to be_locked(resource_key)
      end
    end

    context 'when lock is not available' do
      it 'returns false' do
        lock_info = lock_manager.lock(resource_key, ttl)
        lock_manager.unlock(lock_info)
        expect(lock_manager).not_to be_locked(resource_key)
      end
    end
  end

  describe 'valid_lock?' do
    context 'when lock is available' do
      after(:each) { lock_manager.unlock(@lock_info) if @lock_info }

      it 'returns true' do
        @lock_info = lock_manager.lock(resource_key, ttl)
        expect(lock_manager).to be_valid_lock(@lock_info)
      end
    end

    context 'when lock is not available' do
      it 'returns false' do
        lock_info = lock_manager.lock(resource_key, ttl)
        lock_manager.unlock(lock_info)
        expect(lock_manager).not_to be_valid_lock(lock_info)
      end
    end
  end

  describe '#default_time_source' do
    context 'when CLOCK_MONOTONIC is available (MRI, JRuby)' do
      it 'returns a callable using Process.clock_gettime()' do
        skip 'CLOCK_MONOTONIC not defined' unless defined?(Process::CLOCK_MONOTONIC)
        expect(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_call_original
        Redlock::Client.default_time_source.call()
      end
    end

    context 'when CLOCK_MONOTONIC is not available' do
      it 'returns a callable using Time.now()' do
        cm = Process.send(:remove_const, :CLOCK_MONOTONIC)
        expect(Time).to receive(:now).and_call_original
        Redlock::Client.default_time_source.call()
        Process.const_set(:CLOCK_MONOTONIC, cm) if cm
      end
    end
  end
end
