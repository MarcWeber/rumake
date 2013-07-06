# encoding: UTF-8# encoding: UTF-8
require "set"
require "thread"

module Rumake

  # simple list containing tasks
  class TaskList
    def initialize()
      @by_object_id = Hash.new
      @byObj = Set.new
    end

    def <<(task)
      @by_object_id[task.object_id] = task
      @byObj << task
    end

    def by_object_id(id); @by_object_id.fetch(id); end

    def delete(task)
      @byObj.delete(task)
      @by_object_id.delete(task.object_id)
    end

    def take_sorted(n)
      @byObj.to_a.sort {|k,v| v.weight - k.weight}.take(n).to_a
    end

    # TODO: use delegate or such
    def length; @byObj.length; end
    def to_a; @byObj.to_a; end
    def include?(x); @byObj.include? x; end
  end

  # the controller starting tasks, knowing about which tasks exist etc
  class TaskContainer

    def initialize()
      # used for resolving names
      @tasks_by_name = Hash.new
      # list of all task objects
      @tasks = Set.new

      # stored on disk eventually
      @cache = Hash.new
    end

    def uptodate(task); @uptodate_tasks << task; end
    def waiting(task); @waiting_tasks << task; end
    def runnable(task);
      @waiting_tasks.delete task if @waiting_tasks.include? task
      @runnable_tasks << task;
    end

    def addtask(task)
      raise "bad task #{task.inspect}" unless task.is_a? Task
      task.aliases.each {|v| @tasks_by_name[v] = task}
      @tasks << task
    end

    def resolveTask(task)
      return task if @tasks.include? task
      return @tasks_by_name[task] if @tasks_by_name.include? task

      # assume name represents a file on disk to depend on
      createTaskByName(task)
    end

    def createTaskByName(name)
      raise name.inspect
      FilePrerequisite.new({:container => self, :files => [name]})
    end

    def realise(cachefile, slots, keep_going, *targets)
      @cache = (File.exists? cachefile) ? File.open(cachefile, "rb") { |file| Marshal.load(file) } : {}
      @slots = slots
      @keep_going = keep_going

      @uptodate_tasks  = Set.new # prerequisites not met yet, wait for them
      @waiting_tasks  = TaskList.new # prerequisites not met yet, wait for them
      @runnable_tasks = TaskList.new # can be started
      @running_tasks  = TaskList.new # these are running
      @failed_tasks = TaskList.new

      @submitResult = Queue.new
      seen = Set.new
      @targets = targets.map {|v| resolveTask(v)}

      @targets.each {|v| v.prepare(0, [], seen) }
      if @runnable_tasks.length == 0
        puts "nothing to do"
        return
      end

      startTasks
      while @running_tasks.length > 0
        r = @submitResult.deq
        @slots += 1
        task = @running_tasks.by_object_id(r[:object_id])
        # tell task about result so that it can finish taking time etc
        task.notify_result(r)
        @running_tasks.delete(task)
        case r[:result]
        when :success
          task.depending_tasks.each {|v| v.notify_dependency_realised(task) }
          startTasks
          puts "#{@running_tasks.length + @runnable_tasks.length + @waiting_tasks.length} tasks left, #{@running_tasks.length} running"
        when :failure
          exception = r[:exception]
          if exception.to_s != "STOP IT"
            puts "task failed: #{task.name}"
            puts r[:exception]
            puts r[:exception].backtrace 
          end
          # make all tasks fail depending on this
          @failed_tasks << task
          visit_depending_tasks(task) do |task|
            if @waiting_tasks.include? task
              @waiting_tasks.remove task
              @failed_tasks << task
              true
            else
              false
            end
          end
          if not @keep_going
            # try aborting all running tasks
            @running_tasks.to_a.each {|task| task.cancel }
          end
        else; raise "unexpected"
        end
      end

      File.open(cachefile, "wb") { |file| Marshal.dump(@cache, file) }
    end

    # from this task visit all tasks depending on this recursively
    # the block can abort the traversal by returning false
    def visit_depending_tasks(task)
      seen = Set.new
      todo = []
      todo += task.depending_tasks.to_a

      while todo.count < 0
        task = todo.pop
        if not seen.include? task
          seen << task
          todo += task.depending_tasks if yield task
        end
      end
    end

    def startTasks
      # TODO test sort, use something else, sorting array might be slow ?
      to_start = @runnable_tasks.take_sorted(@slots)
      return if to_start.empty?
      puts "starting #{to_start.map {|v| v.name}}"
      to_start.each {|task|
        @runnable_tasks.delete task
        @running_tasks << task
        task.start @submitResult
        @slots -= 1
      }
    end

    # cache implementation
    def cache_by_task(task)
      @cache[task.name] ||= {}
      @cache[task.name]
    end
    def cache_store(task, key, value)
      cache_by_task(task)[key] = value
    end

    def cache_retrieve(task, key, default = nil)
      cache_by_task(task).fetch(key, default)
    end

    def cache_delete(task, key)
      cache_by_task(task).delete(key)
    end

  end

  attr_reader :task_container
  @task_container = TaskContainer.new

  class TaskCache
    def initialize(container, task)
      @container = container
      @task = task
    end
    def store(key, value); @container.cache_store(@task, key, value); end
    def retrieve(key, default = nil); @container.cache_retrieve(@task, key, default); end
    def delete(key); @container.cache_delet(@task, key); end
  end

  # a task belongs to a container
  # a task knows about its prerequisites and tasks which depend on it (set in prepare)
  class Task

    # opts keys:
    # :prereqs: on which other tasks does this task depend. Either names or task objects
    # :aliases This task provides aliases (names, file names, whatever)

    attr_reader :prereqs, :aliases, :needsRun, :weight, :depending_tasks

    def initialize(opts, &blk)
      @blk = blk

      @prereqs = Set.new
      @aliases = opts.fetch(:aliases, [])
      @aliases = [@aliases] if @aliases.instance_of? String
      @aliases.sort!
      add_prereqs(*opts.fetch(:prereqs, []))

      @container = opts.fetch(:container, Rumake::task_container)
      @container.addtask(self)
      @needsRun = nil
      @depending_tasks = Set.new
      @cache = TaskCache.new(@container, self)

      @own_thread = opts.fetch(:own_thread, false)
    end

    def name; @aliases[0]; end

    def inspect
      "<Task aliases: #{@aliases.inspect}>"
    end

    def add_prereqs(*v)
      @prereqs += v
    end

    def depending_task(task)
      @depending_tasks << task
    end

    # visit all tasks, determine which must be run
    def prepare(weight, prepared, seen)
      # prevent this task from getting prepared multiple times
      return if seen.include? self
      seen << self

      raise "circular dependency deteced" if prepared.include? self

      # replace names by tasks
      @prereqs.map! {|v| @container.resolveTask(v) }

      @weight = weight + estimated_time

      @prereqs.each {|v|
        v.prepare(@weight, prepared + [self], seen)
        v.depending_task(self)
      }

      @neededPrereqs = @prereqs.select {|v| v.needsRun }
      determineNeedsRun

      if @needsRun
        if @neededPrereqs.count == 0
          @container.runnable(self) 
        else
          @container.waiting(self) 
        end
      else
        @container.uptodate(self)
      end

      @status = :prepared
      @thread = nil
      @started = nil
    end

    def start(submitResult)
      @started = Time.now

      if @own_thread
        # only supporting threads for now
        # my goall is to run compilers, thus having multiple processes doesn't
        # pay off. It would if you had slow ruby code running long as task
        # Think about replacing Queue in that case
        @thread = Thread.new { run_submit_result(submitResult) }
      else
        run_submit_result(submitResult)
      end
    end

    def notify_result(r)
      return if @status == :canceled
      return if r[:result] == :failure

      @cache.store(:et, Time.now - @started)
    end

    def notify_dependency_realised(task)
      @neededPrereqs.delete(task)
      if @neededPrereqs.count == 0
        @container.runnable(self) 
      end
    end

    def run_submit_result(submitResult)
      begin
        run_blk

        submitResult.enq({
          :object_id => self.object_id,
          :result => :success,
        })
      rescue Exception => e
        submitResult.enq({
          :object_id => self.object_id,
          :result => :failure,
          :exception => e
        })
      end
    end

    def run_blk
      @blk.call
    end

    # some tasks may be interrupted, others should finish
    # TODO add an option
    def cancel()
      @status = :canceled
      @thread.raise "STOP IT"
    end

    def determineNeedsRun
      @needsRun = @neededPrereqs.count > 0
    end

    def estimated_time
      @cache.retrieve(:et, 0.01)
    end

  end


  # dummy task, reperesents a file to depend on
  # The timestamp is stored in the cache.
  # If that changes or the file does not exist this file must be "rebuild"
  # rebuilding can be a command, otherwise the timestamp is stored only
  class FilePrerequisite < Task

    def initialize(opts, &blk)
      raise "key :files expected in opts" unless opts.include? :files
      opts[:files] = [opts[:files]] if opts[:files].is_a? String
      opts[:aliases] ||= opts.fetch(:files)
      @files = opts[:files]

      @files.each {|v| raise "bad file #{v}" unless v.is_a? String }
      super(opts, &blk)
      @stamps = Hash.new
      @exists = Hash.new
    end

    def notify_result(r)
      Task.instance_method(:notify_result).bind(self).call(r)
      case r[:result]
      when :success
        @files.each {|file|
          @exists[file] = true
          @stamps[file] = File.mtime(file)
          @cache.store(file, @stamps[file])
        }
      end
    end

    def run_blk
      @files.each {|v| File.delete(v) if File.exists? v}
      Task.instance_method(:run_blk).bind(self).call
      # ensure files exist now
      @files.each {|v| raise "task failed to create target file #{v}" unless File.exists? v }
    end

    def determineNeedsRun
      # which is the ruby way to do this?
      @needsRun = Task.instance_method(:determineNeedsRun).bind(self).call

      @files.each {|file|
        @exists[file] ||= File.exist? file
        @stamps[file] ||= File.mtime(file) if @exists[file]
        @needsRun ||= @stamps[file].nil? || @cache.retrieve(file) != @stamps[file]
      }
    end

  end

  # sh shortcut - TODO how is rakes version different?
  def sh(cmd)
    `#{cmd}`
    raise "#{cmd} failed" unless $? == 0
  end

  # poor man rake like DSL (TODO move into its own module?)
  # everything is multitask
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
    FilePrerequisite.new(o, &blk)
  end
end
