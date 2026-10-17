# Array#clear on an Array of one class's objects empties it in place; the
# Array keeps its element type (sp_PtrArray) rather than going polymorphic.
class Item
  attr_reader :n
  def initialize(n); @n = n; end
end

a = [Item.new(1), Item.new(2)]
a.clear
p a.size
p a.empty?
a << Item.new(3)
puts a[0].n
p a.size

class Holder
  def initialize; @items = []; end
  def add(i); @items << i; self; end
  def reset; @items.clear; nil; end
  def total
    t = 0
    @items.each { |i| t += i.n }
    t
  end
  def size; @items.size; end
end

h = Holder.new
h.add(Item.new(4)).add(Item.new(5))
puts h.total
h.reset
p h.size
h.add(Item.new(6))
puts h.total

b = []
b << Item.new(7)
c = b
b.clear
p c.size
c << Item.new(8)
puts b[0].n

d = [Item.new(9)]
r = d.clear
p r.equal?(d)
p d.size
