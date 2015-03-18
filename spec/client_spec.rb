require 'spec_helper'
require 'securerandom'

RSpec.describe Redlock::Client do
  let(:lock_manager) { Redlock::Client.new([ "redis://127.0.0.1:7777", "redis://127.0.0.1:7778", "redis://127.0.0.1:7779" ]) }
  let(:resource_key) { SecureRandom.hex(3)  }
  let(:ttl) { 1000 }

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
  end

  describe 'unlock' do
    before { @lock_info = lock_manager.lock(resource_key, ttl) }

    it 'unlocks' do
      expect(resource_key).to_not be_lockable(lock_manager, ttl)

      lock_manager.unlock(@lock_info)

      expect(resource_key).to be_lockable(lock_manager, ttl)
    end
  end
end
