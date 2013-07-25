# encoding: UTF-8
#
# TODO: implement marking PHONY tasks

module Rumake

  class TaskContainer
    def makefile(lines, errors)
      @tasks.each {|v| v.makefile(lines, errors)}
    end
  end

  class Task

    def makefile_entry(lines, target, dependencies, cmds)
      lines << "#{target}: #{dependencies.join(' ')}"
      cmds.each {|v|
        lines << "\t#{v}"
      }
      lines << ""
    end

    def makefile_lines(lines, targets, dependencies, cmds)
      main_target = targets.first
      makefile_entry(lines, main_target, dependencies, cmds)
      targets.drop(1).each { |t| makefile_entry(lines, t, [main_target], []) }
    end

    def makefile(lines, errors)
      prereqs = @prereqs.map {|v|
        case v
        when String; v # happens if task was not prepared
        when Rumake::Task; v.name
        else raise "unexpected #{v.inspect}"
        end
      }
      if @action.respond_to? :shell_commands
        makefile_lines(lines, @aliases, prereqs, @action.shell_commands)
      elsif @action.nil?
        # eventually touch target (file/dir case) to prevent rebuilding
        # for tasks which don't have a builder
        makefile_lines(lines, @aliases, prereqs, [])
      elsif @action.nil?
        # only dependencies, no target
        makefile_lines(lines, @aliases, prereqs, [])
      else
        errors << "task #{name} cannot be expressed as shell command"
      end
    end

  end
end
