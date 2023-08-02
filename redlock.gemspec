# frozen_string_literal: true

lib = File.expand_path('lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'redlock/version'

Gem::Specification.new do |spec|
  spec.name          = 'redlock'
  spec.version       = Redlock::VERSION
  spec.authors       = ['Leandro Moreira']
  spec.email         = ['leandro.ribeiro.moreira@gmail.com']
  spec.summary       = 'Distributed lock using Redis written in Ruby.'
  spec.description   = 'Distributed lock using Redis written in Ruby. Highly inspired by https://github.com/antirez/redlock-rb.'
  spec.homepage      = 'https://github.com/leandromoreira/redlock-rb'
  spec.license       = 'BSD-2-Clause'

  spec.files         = `git ls-files -z`.split("\x0")
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ['lib']

  spec.add_dependency 'redis-client', '>= 0.14.1', '< 1.0.0'

  spec.add_development_dependency 'connection_pool', '~> 2.2'
  spec.add_development_dependency 'coveralls', '~> 0.8'
  spec.add_development_dependency 'json', '>= 2.3.0', '~> 2.3.1'
  spec.add_development_dependency 'rake', '>= 11.1.2', '~> 13.0'
  spec.add_development_dependency 'rspec', '~> 3', '>= 3.0.0'
end
