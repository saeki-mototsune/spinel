# A CPU-bound thread is still timesliced right after a burst of I/O parks and
# wakes. Those leave the monitor in short timed waits, and a green thread's run
# then skips the wake it used to send the monitor (it comes back within a
# quantum on its own and starts ticking): the spinner below must still be
# preempted, or the sleeper -- on the same, only worker -- never runs and the
# spinner runs out its whole budget.
ENV["SPINEL_WORKERS"] = "1"

r, w = IO.pipe
r2, w2 = IO.pipe
echo = Thread.new do
  200.times do
    r.wait_readable(5.0)
    w2.write(r.readpartial(16))
  end
end
200.times do
  w.write("x")
  r2.wait_readable(5.0)
  r2.readpartial(16)
end
echo.join

flag = false
sleeper = Thread.new { sleep 0.01; flag = true }
spinner = Thread.new do
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  n = 0
  until flag
    n += 1
    break if Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0 > 5.0
  end
  flag
end
sleeper.join
puts spinner.value ? "preempted" : "starved"
