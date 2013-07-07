# encoding: UTF-8

# github.com/MarcWeber/rumake

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
    def each(&blk); @byObj.each(&blk); end
    def map(&blk); @byObj.map(&blk); end
    def sort(&blk); @byObj.sort(&blk); end

    class << self
      def [](*x)
        t = TaskList.new
        x.each {|v| t << v}
        t
      end
    end
  end

  # used for ETA only, does nothing
  class ETATask
    attr_reader :id, :needsRun, :weight, :name, :neededPrereqs
    attr_accessor :eta
    def initialize(id, needsRun, neededPrereqs, weight, eta, name)
      @id = id
      @needsRun = needsRun
      @neededPrereqs = neededPrereqs
      @weight = weight
      @eta = eta
      @name = name
    end

    def startTasks(submitResult)
    end

    def start(blk); end

    class << self
      def fromTask(task)
        raise "bad eta #{task.name}" if task.eta.nil?
        new(task.object_id, task.needsRun, task.neededPrereqs.map {|task|
          raise "bad" unless task.is_a? Task
          task.object_id
        }, task.weight, task.eta, task.name)
      end
    end
  end

  class BuildState
    attr_accessor :uptodate_tasks, :waiting_tasks, :runnable_tasks, :running_tasks, :failed_tasks, :slots

    def initialize(slots, verbose = true)
      @slots = slots
      @verbose = verbose

      @uptodate_tasks  = Set.new # prerequisites not met yet, wait for them
      @waiting_tasks  = TaskList.new # prerequisites not met yet, wait for them
      @runnable_tasks = TaskList.new # can be started
      @running_tasks  = TaskList.new # these are running
      @failed_tasks = TaskList.new
    end


    # returns amount of started tasks
    def startTasks(&submitResult)
      # TODO test sort, use something else, sorting array might be slow ?
      to_start = @runnable_tasks.take_sorted(@slots)
      return 0 if to_start.empty?
      puts "starting #{to_start.map {|v| v.name}}" if @verbose
      to_start.each {|task|
        @runnable_tasks.delete task
        @running_tasks << task
        task.start submitResult
        @slots -= 1
      }
      return to_start.length
    end

  end

  # the controller starting tasks, knowing about which tasks exist etc
  class TaskContainer

    def self.instance
      @@default_instance ||= TaskContainer.new
    end

    def initialize()
      # used for resolving names
      @tasks_by_name = Hash.new
      # list of all task objects
      @tasks = Set.new

      # stored on disk eventually
      @cache = Hash.new
    end

    def uptodate(task); @bs.uptodate_tasks << task; end
    def waiting(task); @bs.waiting_tasks << task; end
    def runnable(task);
      @bs.waiting_tasks.delete task if @bs.waiting_tasks.include? task
      @bs.runnable_tasks << task;
    end

    def addtask(task)
      raise "bad task #{task.inspect}" unless task.is_a? Task
      raise "duplicate task #{task.name}" if @tasks_by_name.include? task.name
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
      FileTask.new({:container => self, :files => [name]}) do
      end
    end

    def initGuard
      raise "call .init first" unless @slots
    end

    def init(cachefile, slots)
      @cachefile = cachefile
      @cache = (File.exists? cachefile) ? File.open(cachefile, "rb") { |file| Marshal.load(file) } : {}
      @slots = slots
    end

    def list(targets = nil)
      initGuard
      targets = @tasks_by_name.keys unless targets
      prepare(targets)
      @tasks.each {|v|
        puts "task #{v.inspect} : weight: #{v.weight}"
      }
    end

    def prepare(targets)
      @bs = BuildState.new(@slots)

      @submitResult = Queue.new
      seen = Set.new
      puts "preparing #{targets.inspect}"
      @targets = targets.map {|v| resolveTask(v)}

      @targets.each {|v| v.prepare(0, [], seen) }
      if @bs.runnable_tasks.length == 0
        puts "nothing to do"
        return
      end
    end

    # simulate build based on previous :eta timings to find out how long the build is likely to take
    def eta(*targets)
      initGuard
      prepare(targets)
      eta_prepared
    end

    def eta_prepared

      bs = BuildState.new(@slots, false)

      # waiting tasks -> runnable tasks if no more prereqs have to run

      bs.runnable_tasks = TaskList[*@bs.runnable_tasks.map {|task| ETATask.fromTask task }]
      bs.waiting_tasks = TaskList[*@bs.waiting_tasks.map {|task| ETATask.fromTask task }]

      m = Hash.new
      (bs.running_tasks.to_a + bs.waiting_tasks.to_a).each {|eta_t|
        eta_t.eta = 0 unless eta_t.needsRun
        m[eta_t.id] = eta_t
      }

      # now simulate the task
      slots = @slots

      total_time_secs = 0

      while true

        bs.waiting_tasks.to_a.each {|t|
          if t.neededPrereqs.empty?
            bs.runnable_tasks << t 
            bs.waiting_tasks.delete t
          end
        }

        break if bs.running_tasks.length == 0 && bs.runnable_tasks.length == 0

        started = bs.startTasks {}
        break if bs.running_tasks.length == 0

        #finish fastest task
        end_task = bs.running_tasks.sort {|k,v| k.eta - v.eta }[0]
        bs.slots += 1
        bs.running_tasks.delete end_task
        total_time_secs += end_task.eta
        bs.running_tasks.each {|t| t.eta -= end_task.eta}

        m.values.each {|t| t.neededPrereqs.delete end_task.id }
      end

      if bs.waiting_tasks.length > 0
        puts "slots: #{bs.slots}"
        puts "something went wrong"
        puts "waiting tasks: #{bs.waiting_tasks.length}"
        puts "runnable tasks: #{bs.runnable_tasks.length}"
        bs.waiting_tasks.each {|task|
          puts "name: #{task.name}  needed prereqs: #{task.neededPrereqs.map {|id| @tasks.detect {|t| t.object_id == id }.name }.inspect}"
        }
        raise "unexpected"
      end
      total_time_secs
    end

    def realise(opts)
      keep_going = opts.fetch(:keep_going, false)
      targets = opts.fetch(:targets)
      show_eta = opts.fetch(:show_eta, true)

      initGuard
      @keep_going = keep_going

      prepare(targets)

      puts "eta: #{eta_prepared} secs" if show_eta


      @bs.startTasks {|v| @submitResult.enq v }
      while @bs.running_tasks.length > 0
        r = @submitResult.deq
        @bs.slots += 1
        task = @bs.running_tasks.by_object_id(r[:object_id])
        # tell task about result so that it can finish taking time etc
        task.notify_result(r)
        @bs.running_tasks.delete(task)
        case r[:result]
        when :success
          task.depending_tasks.each {|v| v.notify_dependency_realised(task) }
          @bs.startTasks {|v| @submitResult.enq v }
          puts "#{@bs.running_tasks.length + @bs.runnable_tasks.length + @bs.waiting_tasks.length} tasks left, #{@bs.running_tasks.length}"
        when :failure
          exception = r[:exception]
          if exception.to_s != "STOP IT"
            puts "task failed: #{task.name}"
            puts r[:exception]
            puts r[:exception].backtrace 
          end
          # make all tasks fail depending on this
          @bs.failed_tasks << task
          visit_depending_tasks(task) do |task|
            if @bs.waiting_tasks.include? task
              @bs.waiting_tasks.remove task
              @bs.failed_tasks << task
              true
            else
              false
            end
          end
          if not @keep_going
            # try aborting all running tasks
            @bs.running_tasks.to_a.each {|task| task.cancel }
          end
        else; raise "unexpected"
        end
      end

      File.open(@cachefile, "wb") { |file| Marshal.dump(@cache, file) }
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

    attr_reader :prereqs, :aliases, :needsRun, :timestamp, :weight, :depending_tasks, :neededPrereqs

    def initialize(opts, &blk)
      @blk = blk

      @prereqs = Set.new
      @aliases = opts.fetch(:aliases, [])
      @aliases = [@aliases] if @aliases.is_a? String or @aliases.is_a? Symbol
      @aliases.sort!
      add_prereqs(*opts.fetch(:prereqs, []))

      @container = opts.fetch(:container, Rumake::TaskContainer.instance)
      @container.addtask(self)
      @depending_tasks = Set.new
      @cache = TaskCache.new(@container, self)

      @own_thread = opts.fetch(:own_thread, false)

      # phony true: always run task
      @phony = opts.fetch(:phony, false)
      @prepared = false
    end

    def name; @aliases[0]; end

    def inspect
      "<Task aliases: #{@aliases.inspect} #{@needsRun ? "needs run" : ""} :depends #{@prereqs.map {|v| v.name}}>"
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
      @prereqs.each {|p|
        raise "bad prereq #{p} of #{name}" unless p.is_a? Task
      }

      @weight = weight + eta

      @prereqs.each {|v|
        v.prepare(@weight, prepared + [self], seen)
        v.depending_task(self)
      }

      @neededPrereqs = @prereqs.select {|v| v.needsRun }
      @state = (@neededPrereqs.count > 0 || @prereqs.any? {|p| p.needsRun }) \
        ? {:needsRun => true} \
        : determineState
      if not @state.include? :needsRun
        p_stamp = @prereqs.map {|p| p.timestamp }.compact.max
        @state = {:needsRun => p_stamp.nil? ? false : p_stamp > @state[:timestamp]}
      end

      if needsRun
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
      @prepared = true
    end

    def needsRun
      @state[:needsRun]
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

      @cache.store(:eta, Time.now - @started)
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

        submitResult.call({
          :object_id => self.object_id,
          :result => :success,
        })
      rescue Exception => e
        submitResult.call({
          :object_id => self.object_id,
          :result => :failure,
          :exception => e
        })
      end
    end

    def run_blk
      @blk.call if @blk
    end

    # some tasks may be interrupted, others should finish
    # TODO add an option
    def cancel()
      @status = :canceled
      @thread.raise "STOP IT" if @thread
    end

    def timestamp
      @state[:timestamp]
    end

    def needsRun
      @state[:needsRun]
    end

    # must return either :needsRun or :timestamp
    # its only called if no of the @prereqs needs to be run
    def determineState
      return {:needsRun => @phony}
    end

    def eta
      eta = @cache.retrieve(:eta)
      eta.nil? ? 0.01 : eta
    end

  end


  # The timestamp is stored in the cache.
  # If that changes or the file does not exist this file must be "rebuild"
  # rebuilding can be a command, otherwise the timestamp is stored only
  class FileTask < Task

    def initialize(opts, &blk)
      raise "blk is nil" if blk.nil?
      raise "key :files expected in opts" unless opts.include? :files
      opts[:files] = [opts[:files]] if opts[:files].is_a? String
      opts[:aliases] ||= opts.fetch(:files)
      @files = opts[:files]

      @files.each {|v| raise "bad file #{v}" unless v.is_a? String }
      super(opts, &blk)
      @stamps = Hash.new
      @exists = Hash.new
    end

    def determineState
      return {:needsRun => true } if @files.any? {|file| not File.exists? file }
      return {:timestamp => @files.each {|file| File.mtime(file) }.max }
    end

    def run_blk
      # @files.each {|v| File.delete(v) if File.exists? v}
      Task.instance_method(:run_blk).bind(self).call
      # ensure files exist now
      @files.each {|v| raise "task failed to create target file #{v}. This usually means there is no rule to build this file." unless File.exists? v }
    end

  end

  # be happy if the directory exists
  class DirTask < Task

    def initialize(opts, &blk)
      raise "blk is nil" if blk.nil?
      raise "key :dirs expected in opts" unless opts.include? :dirs
      opts[:dirs] = [opts[:dirs]] if opts[:dirs].is_a? String
      opts[:aliases] ||= opts.fetch(:dirs)
      @dirs = opts[:dirs]

      @dirs.each {|v| raise "bad file #{v}" unless v.is_a? String }
      super(opts, &blk)
      @exists = Hash.new
    end

    def run_blk
      @files.each {|v| File.delete(v) if File.exists? v}
      Task.instance_method(:run_blk).bind(self).call
      # ensure files exist now
      @dirs.each {|dir| raise "task failed to create target directory #{dir}" unless Dir.exists? v }
    end

    def determineState
      return {:needsRun => @dirs.any? {|dir| not Dir.exist? dir } }
    end

  end

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
    FileTask.new(o, &blk)
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
    DirTask.new(o, &blk)
  end

end
