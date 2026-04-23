#!/usr/bin/env ruby
# frozen_string_literal: true

$stdout.sync = true
$stderr.sync = true

require "dotenv/load"
require_relative "lib/ezclaw"
require "optparse"

options = { mode: :production }

OptionParser.new do |opts|
  opts.banner = "Usage: ezclaw.rb --bot <path> [options]"

  opts.on("--bot PATH", "Path to bot config directory") do |path|
    options[:bot] = path
  end

  opts.on("--data PATH", "Path to writable data directory (default: <bot>/data or $EZCLAW_DATA_DIR)") do |path|
    options[:data] = path
  end

  opts.on("--repl", "Run in interactive REPL mode (no Slack, no cron)") do
    options[:mode] = :repl
  end

  opts.on("--dry", "Dry run: trigger each schedule once, print output, exit") do
    options[:mode] = :dry
  end

  opts.on("-v", "--version", "Print version") do
    puts "Ezclaw v#{Ezclaw::VERSION}"
    exit
  end

  opts.on("-h", "--help", "Show help") do
    puts opts
    exit
  end
end.parse!

unless options[:bot]
  puts "Error: --bot <path> is required"
  puts "Run with --help for usage"
  exit 1
end

unless Dir.exist?(options[:bot])
  puts "Error: bot directory not found: #{options[:bot]}"
  exit 1
end

bot = Ezclaw::Bot.new(bot_dir: options[:bot], data_dir: options[:data])
bot.run(mode: options[:mode])
