# An Object#detect the program defines answers a receiverless detect in a
# class method, in an instance method and at the top level, though detect
# is find under another name for an Enumerable, and an Array's detect
# still takes Enumerable's.
class Object
  def detect = :obj_detect
end
class C
  def self.go = detect
  def go = detect
end
p C.go
p C.new.go
p detect
p [1, 2].detect { |x| x > 1 }
