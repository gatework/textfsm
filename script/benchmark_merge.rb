# frozen_string_literal: true

require_relative "../lib/textfsm/table"

# 多对一合并包含嵌套值时，测量重复匹配右行的遍历与分配开销。
row_count = Integer(ENV.fetch("ROWS", "10000"), 10)
item_count = Integer(ENV.fetch("ITEMS", "200"), 10)
raise ArgumentError, "ROWS and ITEMS must be positive" unless row_count.positive? && item_count.positive?

left = TextFSM::Table.new(%w[ID LEFT], Array.new(row_count) { %w[same left] })
items = Array.new(item_count) { |index| { "name" => "item-#{index}", "tags" => %w[one two] } }
right = TextFSM::Table.new(%w[ID ITEMS], [["same", items]])

3.times do
  GC.start
  allocated = GC.stat(:total_allocated_objects)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  merged = left.merge(right, keys: ["ID"])
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  objects = GC.stat(:total_allocated_objects) - allocated
  raise "Unexpected merge result" unless merged.size == row_count && merged[-1][-1] == items && left.header == %w[ID LEFT]

  puts format("rows=%<rows>d items=%<items>d seconds=%<seconds>.6f allocated_objects=%<objects>d",
              rows: row_count, items: item_count, seconds: elapsed, objects: objects)
end
