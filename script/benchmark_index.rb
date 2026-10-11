# frozen_string_literal: true

require "tmpdir"
require_relative "../lib/textfsm/index_table"

# 测量较晚命中时的索引加载、扫描耗时与对象分配，不代表所有查询分布。
row_count = Integer(ENV.fetch("ROWS", "2000"), 10)
query_count = Integer(ENV.fetch("QUERIES", "500"), 10)
raise ArgumentError, "ROWS and QUERIES must be positive" unless row_count.positive? && query_count.positive?

def measure(label)
  GC.start
  allocated = GC.stat(:total_allocated_objects)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  yield
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  objects = GC.stat(:total_allocated_objects) - allocated
  puts format("%<label>s seconds=%<seconds>.6f allocated_objects=%<objects>d",
              label: label, seconds: elapsed, objects: objects)
end

Dir.mktmpdir("textfsm-index-benchmark-") do |directory|
  path = File.join(directory, "index")
  File.open(path, "w") do |file|
    file.puts("Template,Vendor,Platform,Command")
    row_count.times { |number| file.puts("template#{number},Vendor\\Z,Platform\\Z,show #{number}\\Z") }
  end
  attributes = { Vendor: "Vendor", Platform: "Platform", Command: "show #{row_count - 1}" }.freeze
  3.times do
    index = nil
    measure("load rows=#{row_count}") do
      index = TextFSM::IndexTable.new(path, compile: ->(key, value) { value unless key == "Template" })
      raise "Unexpected index size" unless index.size == row_count
    end
    measure("match queries=#{query_count}") do
      query_count.times do
        raise "Unexpected index match" unless index.match(attributes)&.fetch("Template") == "template#{row_count - 1}"
      end
    end
  end
end
