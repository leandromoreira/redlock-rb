require './redlock.rb'

def thread_main(count)
    dlm = Redlock.new("redis://127.0.0.1:6379","redis://127.0.0.1:6380","redis://127.0.0.1:6381")

    incr=0
    count.times {
        my_lock = dlm.lock("foo",1000)
        if my_lock
            if my_lock[:validity] > 500
                # Note: we assume we can do it in 500 milliseconds. If this
                # assumption is not correct, the program output will not be
                # correct.
                number = File.read("/tmp/counter.txt")
                File.write("/tmp/counter.txt",(number.to_i+1).to_s)
                incr += 1
            end
            dlm.unlock(my_lock)
        end
    }
    puts "/tmp/counter.txt incremented #{incr} times."
end

File.write("/tmp/counter.txt","0")
threads=[]
5.times {
    threads << Thread.new{thread_main(100)}
}
threads.each{|t| t.join}
puts "Counter value is #{File.read("/tmp/counter.txt")}"
