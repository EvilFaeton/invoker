require "io/console"
require 'pty'

module Invoker
  class Commander
    MAX_PROCESS_COUNT = 10
    LABEL_COLORS = ['green', 'yellow', 'blue', 'magenta', 'cyan']
    attr_accessor :reactor, :workers, :thread_group, :open_pipes
    
    def initialize
      # mapping between open pipes and worker classes
      @open_pipes = {}

      # mapping between command label and worker classes
      @workers = {}
      
      @thread_group = ThreadGroup.new()
      @worker_mutex = Mutex.new()
      @reactor = Invoker::Reactor.new
      Thread.abort_on_exception = true
    end

    def start_manager
      if !Invoker::CONFIG.processes || Invoker::CONFIG.processes.empty?
        raise Invoker::Errors::InvalidConfig.new("No processes configured in config file")
      end
      install_interrupt_handler()
      unix_server_thread = Thread.new { Invoker::CommandListener::Server.new() }
      thread_group.add(unix_server_thread)
      Invoker::CONFIG.processes.each { |process_info| add_command(process_info) }
      reactor.start
    end

    def add_command(process_info)
      m, s = PTY.open
      s.raw! # disable newline conversion.

      pid = run_command(process_info, s)

      s.close()

      selected_color = LABEL_COLORS.shift()
      LABEL_COLORS.push(selected_color)
      worker = Invoker::CommandWorker.new(process_info.label, m, pid, selected_color)

      add_worker(worker)
      wait_on_pid(process_info.label,pid)
    end

    def add_command_by_label(command_label)
      process_info = Invoker::CONFIG.processes.detect {|pconfig|
        pconfig.label == command_label
      }
      if process_info
        add_command(process_info)
      end
    end

    def reload_command(command_label)
      remove_command(command_label)
      add_command_by_label(command_label)
    end

    def remove_command(command_label, rest_args)
      worker = workers[command_label]
      signal_to_use = rest_args ? Array(rest_args).first : 'INT'

      if worker
        $stdout.puts("Removing #{command_label} with signal #{signal_to_use}".red)
        process_kill(worker.pid, signal_to_use)
      end
    end

    def get_worker_from_fd(fd)
      open_pipes[fd.fileno]
    end

    def get_worker_from_label(label)
      workers[label]
    end
    
    private
    def process_kill(pid, signal_to_use)
      if signal_to_use.to_i == 0
        Process.kill(signal_to_use, pid)
      else
        Process.kill(signal_to_use.to_i, pid)
      end
    end
    
    # Remove worker from all collections
    def remove_worker(command_label)
      @worker_mutex.synchronize do
        worker = @workers[command_label]
        if worker
          @open_pipes.delete(worker.pipe_end.fileno)
          @reactor.remove_from_monitoring(worker.pipe_end)
          @workers.delete(command_label)
        end
      end
    end

    # add worker to global collections
    def add_worker(worker)
      @worker_mutex.synchronize do
        @open_pipes[worker.pipe_end.fileno] = worker
        @workers[worker.command_label] = worker
        @reactor.add_to_monitor(worker.pipe_end)
      end
    end

    def run_command(process_info, write_pipe)
      if defined?(Bundler)
        Bundler.with_clean_env do
          spawn(process_info.cmd, 
            :chdir => process_info.dir || "/", :out => write_pipe, :err => write_pipe
          )
        end
      else
        spawn(process_info.cmd, 
          :chdir => process_info.dir || "/", :out => write_pipe, :err => write_pipe
        )
      end
    end

    def wait_on_pid(command_label,pid)
      raise Invoker::Errors::ToomanyOpenConnections if @thread_group.enclosed?
      thread = Thread.new do
        Process.wait(pid)
        message = "Process with command #{command_label} exited with status #{$?.exitstatus}"
        $stdout.puts("\n#{message}".red)
        notify_user(message)
        remove_worker(command_label)
      end
      @thread_group.add(thread)
    end

    def notify_user(message)
      if defined?(Bundler)
        Bundler.with_clean_env do
          check_and_notify_with_terminal_notifier(message)
        end
      else
        check_and_notify_with_terminal_notifier(message)
      end
    end

    def check_and_notify_with_terminal_notifier(message)
      return unless RUBY_PLATFORM.downcase.include?("darwin")

      command_path = `which terminal-notifier`
      if command_path && !command_path.empty?
        system("terminal-notifier -message '#{message}' -title Invoker")
      end
    end

    def install_interrupt_handler
      Signal.trap("INT") do
        @workers.each {|key,worker|
          begin
            Process.kill("INT", worker.pid) 
          rescue Errno::ESRCH
          end
        }
        exit(0)
      end
    end

  end
end
