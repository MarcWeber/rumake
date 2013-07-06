# encoding: UTF-8# encoding: UTF-8
require "rumake/task"

include Rumake

numbers = []
last_char = nil

0.upto(20).each do |n|
  numbers << (file (n.to_s) do
    raise "bad" if n == 10
    sh "echo #{n} > #{n}"
  end)
end

# a-f, f depends on e etc
file "a" do
  sh "echo a > a"
end

%w{b c d e f}.each {|v|
  last_char = file "#{v}" => [(v[0].ord-1).chr] do
    sh "echo #{v} > #{v}"
  end
}

task "all" => [last_char] + numbers do
end



# a-f, f depends on e etc

# file "a" do
#   sh "echo a > a"
# end

# %w{b}.each {|v|
#   last_char = file "#{v}" => [(v[0].ord-1).chr] do
#     sh "echo #{v} > #{v}"
#   end
# }


Rumake::task_container.realise("cache", 4, false, "all")
