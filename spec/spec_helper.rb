# coding: utf-8
require 'coveralls'
Coveralls.wear!
require 'redlock'

LOCK_INFO_KEYS = [:validity, :resource, :value]

RSpec::Matchers.define :be_lock_info_for do |resource|
  def correct_type?(actual)
    actual.is_a?(Hash)
  end

  def correct_layout?(actual)
    ((LOCK_INFO_KEYS | actual.keys) - (LOCK_INFO_KEYS & actual.keys)).empty?
  end

  def correct_resource?(actual, resource)
    actual[:resource] == resource
  end

  match do |actual|
    correct_type?(actual) && correct_layout?(actual) && correct_resource?(actual, resource)
  end

  failure_message do |actual|
    "expected that #{actual} would be lock information for #{expected}"
  end
end

RSpec::Matchers.define :be_lockable do |lock_manager, ttl|
  match do |resource_key|
    begin
      lock_info = lock_manager.lock(resource_key, ttl)
      lock_info != false
    ensure
      lock_manager.unlock(lock_info) if lock_info
    end
  end

  failure_message do |resource_key|
    "expected that #{resource_key} would be lockable"
  end
end

RSpec.configure do |c|
  # NOTE: this protects against erroneous "focus: true" commits
  unless ENV['CI'] == 'true'
    c.filter_run focus: true
    c.run_all_when_everything_filtered = true
  end
end