default: test
test:
	docker-compose run --rm test

build:
	docker-compose run --rm test gem build redlock.gemspec

publish:
	docker-compose run --rm test gem push `ls -lt *gem | head -n 1 | awk '{ print $$9 }'`
