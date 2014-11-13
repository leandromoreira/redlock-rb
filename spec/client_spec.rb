require 'spec_helper'

RSpec.describe Redlock::Client do
  let(:lock_manager) { Redlock::Client.new([ "redis://127.0.0.1:7777", "redis://127.0.0.1:7778", "redis://127.0.0.1:7779" ]) }
  let(:resource_key) { "foo" }
  let(:ttl) { 1000 }

  it 'locks' do
    first_try_lock_info = lock_manager.lock(resource_key, ttl)
    second_try_lock_info = lock_manager.lock(resource_key, ttl)

    expect(first_try_lock_info[:resource]).to eq("foo")
    expect(second_try_lock_info).to be_falsy

    lock_manager.unlock(first_try_lock_info)
  end

  it 'unlocks' do
    lock_info = lock_manager.lock(resource_key, ttl)
    lock_manager.unlock(lock_info)
    another_lock_info = lock_manager.lock(resource_key, ttl)

    expect(another_lock_info[:resource]).to eq("foo")
  end
end
