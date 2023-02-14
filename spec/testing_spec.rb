require 'spec_helper'
require 'securerandom'

require 'redlock/testing'

RSpec.describe Redlock::Client do
  let(:lock_manager) { Redlock::Client.new }
  let(:resource_key) { SecureRandom.hex(3)  }
  let(:ttl) { 1000 }

  describe '(testing mode)' do
    describe 'try_lock_instances' do
      context 'when testing with bypass mode' do
        before { Redlock::Client.testing_mode = :bypass }

        it 'bypasses the redis servers' do
          expect(lock_manager).to_not receive(:try_lock_instances_without_testing)
          lock_manager.lock(resource_key, ttl) do |lock_info|
            expect(lock_info).to be_lock_info_for(resource_key)
          end
        end
      end

      context 'when testing with fail mode' do
        before { Redlock::Client.testing_mode = :fail }

        it 'fails' do
          expect(lock_manager).to_not receive(:try_lock_instances_without_testing)
          lock_manager.lock(resource_key, ttl) do |lock_info|
            expect(lock_info).to eql(false)
          end
        end
      end

      context 'when testing is disabled' do
        before { Redlock::Client.testing_mode = nil }

        it 'works as usual' do
          expect(lock_manager).to receive(:try_lock_instances_without_testing)
          lock_manager.lock(resource_key, ttl) { |lock_info| }
        end
      end
    end
  end
end
