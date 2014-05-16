require './redlock.rb'

dlm = Redlock.new("redis://127.0.0.1:6379","redis://127.0.0.1:6380","redis://127.0.0.1:6381")

while 1
    my_lock = dlm.lock("foo",1000)
    if my_lock
        puts "Acquired by client #{dlm}"
        dlm.unlock(my_lock)
    else
        puts "Error, lock not acquired"
    end
end
