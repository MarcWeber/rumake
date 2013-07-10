# encoding: UTF-8# encoding: UTF-8
require_relative "../lib/rumake/task.rb"
require_relative "../lib/rumake/rakelike.rb"
require "set"

# usage: ruby tests/test.rb all
# usage: ruby tests/test.rb clean
# usage: ruby tests/test.rb list # list tasks and weights

include Rumake::Rakelike

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

  # because the shell_commands are passed as string these will end up in the
  # makefile
  last_char = Rumake::Tasks::File.new({
    :files => v,
    :prereqs => [(v[0].ord-1).chr],
    :shell_commands => "echo #{v} > #{v}"
  })
}

task "all" => [last_char] + numbers do
end

task "clean" do
  # this will not en dup in the makefile because there is no shell_commands setting
  sh "rm #{$files.to_a.join(' ')}"
end


Rumake::Tasks::File.new({
  :files => "makefile",
  :phony => true
  }) do
  require_relative "../lib/rumake/makefile.rb"

  errors = []
  out = []
  Rumake::TaskContainer.instance.makefile(out, errors)
  puts "WARNING: errors while creating makefile:"
  puts errors
  File.open('makefile', "wb") { |file| file.write(out.join("\n")) }
end


# yes, a DSL is still missing
Rumake::TaskContainer.instance.init("rumake.cache", 4)
case ARGV[0]
when "list"
  Rumake::TaskContainer.instance.list
when "eta"
  eta = Rumake::TaskContainer.instance.eta(*ARGV.drop(1))
  puts "#{eta} secs"
else
  Rumake::TaskContainer.instance.realise(
    :targets => ARGV,
    :show_eta => true,
    :keep_going => false
  )
end
