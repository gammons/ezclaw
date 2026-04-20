# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"

class TestMemory < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @config_dir = File.join(@tmpdir, "config")
    @data_dir = File.join(@tmpdir, "data")
    Dir.mkdir(@config_dir)
    Dir.mkdir(@data_dir)
    File.write(File.join(@config_dir, "memory.md"), "# Initial Memory\nBaseline data.")
  end

  def teardown
    FileUtils.remove_entry(@tmpdir)
  end

  def test_read_from_data_dir_if_exists
    File.write(File.join(@data_dir, "memory.md"), "# Updated Memory\nNew data.")
    mem = Grantclaw::Memory.new(config_dir: @config_dir, data_dir: @data_dir, filename: "memory.md")
    assert_includes mem.read, "New data."
  end

  def test_copies_from_config_on_first_read
    mem = Grantclaw::Memory.new(config_dir: @config_dir, data_dir: @data_dir, filename: "memory.md")
    content = mem.read
    assert_includes content, "Baseline data."
    assert File.exist?(File.join(@data_dir, "memory.md"))
  end

  def test_update_writes_to_data_dir
    mem = Grantclaw::Memory.new(config_dir: @config_dir, data_dir: @data_dir, filename: "memory.md")
    mem.update("# New Content\nUpdated.")
    assert_equal "# New Content\nUpdated.", File.read(File.join(@data_dir, "memory.md"))
  end

  def test_read_returns_empty_string_if_no_file
    mem = Grantclaw::Memory.new(config_dir: @config_dir, data_dir: @data_dir, filename: "nonexistent.md")
    assert_equal "", mem.read
  end
end
