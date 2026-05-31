#!/usr/bin/env ruby

require 'ruby_llm'
require 'readline'
require 'dotenv/load'

WORKSPACE = ARGV[0] || File.expand_path('workspace', __dir__)
TEMPLATES = File.expand_path('templates', __dir__)

# --- sandbox: bubblewrap, workspace is the only writable host path ---

def sandbox(cmd)
  if ENV["NOSANDBOX"] == "true"
    system(cmd)
  else
    system 'bwrap', '--die-with-parent', '--unshare-all', '--share-net',
      '--tmpfs', '/tmp', '--proc', '/proc', '--dev', '/dev',
      '--ro-bind', '/bin', '/bin', '--ro-bind', '/usr', '/usr',
      '--ro-bind', '/lib', '/lib', '--ro-bind', '/lib64', '/lib64',
      '--bind', WORKSPACE, '/workspace', '--chdir', '/workspace',
      'bash', '-lc', cmd
  end
  $?.success? ? 'OK' : "ERR #{$?.exitstatus}"
end

# --- tools: the agent's only interface to the world ---

class Read  < RubyLLM::Tool
  description 'Read a file'
  param :path

  def execute(path:)
    puts "-- Reading #{path}"
    IO.read(File.join(WORKSPACE, path))
  rescue
    "Error reading #{path}"
  end
end

class Write < RubyLLM::Tool
  description 'Write a file'
  param :path
  param :content

  def execute(path:, content:)
    puts "-- Writing #{path}"
    IO.write(File.join(WORKSPACE, path), content)
    "Wrote #{path}"
  rescue
    "Error writing #{path}"
  end
end

class Bash  < RubyLLM::Tool
  description 'Run a shell command'
  param :command

  def execute(command:)
    puts "-- Executing #{command}"
    sandbox(command)
  end
end

# --- core: load identity, configure LLM, run loop ---

class Core
  FILES = %w[AGENTS.md IDENTITY.md SOUL.md MEMORY.md]

  EXIT_MESSAGE = %{
    This session is ending. If there is something you want to remember, this is your last chance to save it
  }
  
  def initialize
    model    = ENV['MODEL']
    provider = ENV['PROVIDER']
    key_var  = ENV['API_KEY']
    api_base = ENV['API_BASE']

    RubyLLM.configure do |c|
      c.send("#{provider}_api_key=", key_var)
      c.send("#{provider}_api_base=", api_base) if api_base
    end

    setup_workspace

    parts = []

    Core::FILES.each do |f|
      file = File.join(WORKSPACE, f)
      parts << IO.read(file) rescue nil
    end

    opts = { model: model }
    begin
      RubyLLM::Models.resolve(model)
    rescue
      # Handle e.g. OpenRouter models that RubyLLM is unaware of.
      opts[:assume_model_exists] = true
      opts[:provider] = provider.to_sym
    end
    
    @chat = RubyLLM.chat(**opts)
    @chat.with_instructions parts.compact.join("\n---\n")
    @chat.with_tools Read, Write, Bash
  end

  def quit
    @chat.ask(EXIT_MESSAGE)
  end
  
  def setup_workspace
    Dir.mkdir(WORKSPACE) rescue nil

    FILES.each do |f|
      src = File.join(TEMPLATES, f)
      dst = File.join(WORKSPACE, f)
      File.write(dst, IO.read(src)) rescue nil unless File.exist?(dst)
    end
  end

  def ask(msg)
    @chat.ask(msg) do |c|
      print c.content
    end
    puts
  end
end

# -- How the agent talks to the outside world
#
# In a "proper" Claw, we'd provide adapters to interact with messaging systems (e.g. Whatsapp, Discord)
#

puts "🦾RazorClaw Zero (type 'exit' to quit)"
  
core = Core.new
while (line = Readline.readline('> ', true))
  line.strip!
  break if %w[exit quit].include?(line.downcase)
  next if line.empty?
  core.ask(line)
end

core.quit
