require 'spec_helper'
require 'securerandom'

RSpec.describe Redlock::Client do
  # It is recommended to have at least 3 servers in production
  let(:lock_manager) { Redlock::Client.new }
  let(:resource_key) { SecureRandom.hex(3)  }
  let(:ttl) { 1000 }

  describe 'initialize' do
    it 'accepts both redis URLs and Redis objects' do
      servers = [ 'redis://localhost:6379', Redis.new(url: 'redis://127.0.0.1:6379') ]
      redlock = Redlock::Client.new(servers)

      redlock_servers = redlock.instance_variable_get(:@servers).map do |s|
        s.instance_variable_get(:@redis).client.host
      end

      expect(redlock_servers).to match_array(%w{ localhost 127.0.0.1 })
    end
  end

  describe 'lock' do
    context 'when lock is available' do
      after(:each) { lock_manager.unlock(@lock_info) if @lock_info }

      it 'locks' do
        @lock_info = lock_manager.lock(resource_key, ttl)

        expect(resource_key).to_not be_lockable(lock_manager, ttl)
      end

      it 'returns lock information' do
        @lock_info = lock_manager.lock(resource_key, ttl)

        expect(@lock_info).to be_lock_info_for(resource_key)
      end

      it 'can extend its own lock' do
        my_lock_info = lock_manager.lock(resource_key, ttl)
        @lock_info = lock_manager.lock(resource_key, ttl, extend: my_lock_info)
        expect(@lock_info).to be_lock_info_for(resource_key)
        expect(@lock_info[:value]).to eq(my_lock_info[:value])
      end

      context 'when extend_life flag is given' do
        it 'does not extend a non-existent lock' do
          @lock_info = lock_manager.lock(resource_key, ttl, extend: {value: 'hello world'}, extend_life: true)
          expect(@lock_info).to eq(false)
        end
      end

      context 'when extend_life flag is not given' do
        it "sets the given value when trying to extend a non-existent lock" do
          @lock_info = lock_manager.lock(resource_key, ttl, extend: {value: 'hello world'}, extend_life: false)
          expect(@lock_info).to be_lock_info_for(resource_key)
          expect(@lock_info[:value]).to eq('hello world') # really we should test what's in redis
        end
      end

      it "doesn't extend somebody else's lock" do
        @lock_info = lock_manager.lock(resource_key, ttl)
        second_attempt = lock_manager.lock(resource_key, ttl)
        expect(second_attempt).to eq(false)
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
    end

    context 'when script cache has been flushed' do
      before(:each) do
        @manipulated_instance = lock_manager.instance_variable_get(:@servers).first
        @manipulated_instance.instance_variable_get(:@redis).script(:flush)
      end

      it 'does not raise a Redis::CommandError: NOSCRIPT error' do
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
          expect(@manipulated_instance).to receive(:load_scripts)

          expect {
            lock_manager.lock(resource_key, ttl)
          }.to raise_error(/NOSCRIPT/)
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
        expect { lock_manager.lock!(resource_key, ttl) {} }.to raise_error(Redlock::LockError)
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
end
