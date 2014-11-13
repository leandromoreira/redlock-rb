# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'redlock/version'

Gem::Specification.new do |spec|
  spec.name          = "redlock"
  spec.version       = Redlock::VERSION
  spec.authors       = ["Leandro Moreira"]
  spec.email         = ["leandro.ribeiro.moreira@gmail.com"]
  spec.summary       = %q{Distributed lock using Redis written in Ruby.}
  spec.description   = %q{Distributed lock using Redis written in Ruby. Highly inspired by https://github.com/antirez/redlock-rb.}
  spec.homepage      = "https://github.com/leandromoreira/redlock-rb"
  spec.license       = "MIT"

  spec.files         = `git ls-files -z`.split("\x0")
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]

  spec.add_development_dependency "bundler", "~> 1.7"
  spec.add_development_dependency "rake", "~> 10.0"
  spec.add_development_dependency "rspec", "~> 3.1"
end
