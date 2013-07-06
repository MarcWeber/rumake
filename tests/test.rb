# encoding: UTF-8# encoding: UTF-8
require_relative "../lib/rumake/task.rb"
require "set"

# usage: ruby tests/test.rb all
# usage: ruby tests/test.rb clean
# usage: ruby tests/test.rb list # list tasks and weights

include Rumake

numbers = []
last_char = nil

$files = Set.new

0.upto(20).each do |n|
  $files << n.to_s
  numbers << (file (n.to_s) do
    # raise "bad" if n == 10
    sh "echo #{n} > #{n}"
  end)
end

# a-f, f depends on e etc
file "a" do
  sh "echo a > a"
end
$files << "a"

%w{b c d e f}.each {|v|
  $files << v
  last_char = file "#{v}" => [(v[0].ord-1).chr] do
    sh "echo #{v} > #{v}"
  end
}

task "all" => [last_char] + numbers do
end

task "clean" do
  sh "rm #{$files.to_a.join(' ')}"
end

# yes, a DSL is still missing
Rumake::TaskContainer.instance.init("rumake.cache", 4)
if ARGV[0] == "list"
  Rumake::TaskContainer.instance.list
else
  Rumake::TaskContainer.instance.realise(false, *ARGV)
end
