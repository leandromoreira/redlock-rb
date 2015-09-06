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
    end

    context 'when lock is not available' do
      before { @another_lock_info = lock_manager.lock(resource_key, ttl) }
      after { lock_manager.unlock(@another_lock_info) }

      it 'returns false' do
        lock_info = lock_manager.lock(resource_key, ttl)

        expect(lock_info).to eql(false)
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

    context 'when testing with bypass mode' do
      before { lock_manager.testing = :bypass }
      after { lock_manager.testing = nil }

      it 'bypasses the redis servers' do
        expect(lock_manager).to_not receive(:try_lock_instances)
        lock_manager.lock(resource_key, ttl) do |lock_info|
          expect(lock_info).to be_lock_info_for(resource_key)
        end
      end
    end

    context 'when testing with fail mode' do
      before { lock_manager.testing = :fail }
      after { lock_manager.testing = nil }

      it 'fails' do
        expect(lock_manager).to_not receive(:try_lock_instances)
        lock_manager.lock(resource_key, ttl) do |lock_info|
          expect(lock_info).to eql(false)
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

  describe 'heartbeat' do
    it 'unlocks if the process dies' do
      resource_key # memoize it
      child = nil
      begin
        child = fork do
          lock_manager.lock resource_key, 1000 * 1000              # lock effectively forever
          sleep
        end
        sleep 0.1
        expect(resource_key).not_to be_lockable(lock_manager, ttl) # the other process still has it
        Process.kill 'KILL', child
        expect(resource_key).not_to be_lockable(lock_manager, ttl) # detecting no heartbeat is not instant
        sleep 2
        expect(resource_key).to     be_lockable(lock_manager, ttl) # but now it should be cleared because no heartbeat
      ensure
        Process.kill('KILL', child) rescue Errno::ESRCH
      end
    end
  end
end
