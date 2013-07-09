# encoding: UTF-8
#
# horriblly incomplete. At least you have a task, flile, dir and sh command
#
# no namespaces yet
#
# due to options such as :phony I'm not sure wether this syntax is best !?


module Rumake
  module Rakelike
   # sh shortcut - TODO how is rakes version different?
   def sh(cmd)
     `#{cmd}`
     raise "#{cmd} failed" unless $? == 0
   end

   # poor man rake like DSL (TODO move into its own module?)
   # everything is multitask always
   def task(opts, &blk)
     o = {}
     case opts
     when String
       o[:aliases] = [opts]
     when Hash
       o[:aliases] = opts.keys[0]
       o[:prereqs] = opts.values[0]
     end
     o[:own_thread] = false
     o[:phony] = true
     Task.new(o, &blk)
   end

   def file(opts, &blk)
     o = {}
     case opts
     when String
       o[:files] = [opts]
     when Hash
       raise "one key value expected" unless opts.length == 1
       o[:files] = opts.keys[0]
       o[:prereqs] = opts.values[0]
     end
     o[:own_thread] = true
     Tasks::File.new(o, &blk)
   end


   def dir(opts, &blk)
     o = {}
     case opts
     when String
       o[:dirs] = [opts]
     when Hash
       raise "one key value expected" unless opts.length == 1
       o[:dirs] = opts.keys[0]
       o[:prereqs] = opts.values[0]
     end
     o[:own_thread] = true
     Tasks::Dir.new(o, &blk)
   end

  end
end
