# frozen_string_literal: true

require_relative "../../test_helper"
require "tmpdir"

class TestSlackUploadFile < Minitest::Test
  UploadTool = Ezclaw::Tools::SlackUploadFileTool
  SLACK = { channel: "C0CHAN", thread_ts: "1700.0001", message_ts: "1700.0002", user: "U1", is_dm: false }.freeze
  REPL = { channel: nil, thread_ts: "repl-1", message_ts: nil, user: "repl", is_dm: false }.freeze

  def setup
    @root = Dir.mktmpdir
    @outputs = File.join(@root, "outputs")
    Dir.mkdir(@outputs)
    @csv = File.join(@outputs, "r.csv")
    File.write(@csv, "a,b\n1,2\n")
    @uploads = []
    uploads = @uploads
    client = Object.new
    client.define_singleton_method(:files_upload_v2) { |params| uploads << params; { "ok" => true } }
    UploadTool.slack_client = client
    UploadTool.repl_mode = false
    UploadTool.allowed_roots = [@outputs]
  end

  def teardown
    UploadTool.slack_client = nil
    UploadTool.repl_mode = nil
    UploadTool.allowed_roots = nil
    FileUtils.remove_entry(@root)
  end

  # slack: nil runs the tool outside any conversation (like a cron run).
  def run_tool(args, slack: SLACK)
    return UploadTool.new.execute(args) if slack.nil?

    Ezclaw::SlackContext.with(**slack) { UploadTool.new.execute(args) }
  end

  def test_uploads_to_the_current_thread
    out = run_tool({ "path" => @csv, "filename" => "report.csv", "comment" => "Here it is" })
    assert_match(/Uploaded report.csv/, out)
    up = @uploads.fetch(0)
    assert_equal "C0CHAN", up[:channel_id]
    assert_equal "1700.0001", up[:thread_ts]
    assert_equal "a,b\n1,2\n", up[:content]
    assert_equal "report.csv", up[:filename]
    assert_equal "report.csv", up[:title]
    assert_equal "Here it is", up[:initial_comment]
  end

  def test_has_no_channel_or_thread_parameter
    names = UploadTool.tool_params.map { |p| p[:name] }
    assert_empty names & %i[channel channel_id channels thread_ts]
  end

  def test_extra_channel_arguments_are_ignored
    run_tool({ "path" => @csv, "filename" => "r.csv", "channel" => "C0EVIL", "channel_id" => "C0EVIL", "thread_ts" => "1" })
    assert_equal "C0CHAN", @uploads.fetch(0)[:channel_id]
    assert_equal "1700.0001", @uploads.fetch(0)[:thread_ts]
  end

  def test_filename_is_reduced_to_a_basename
    run_tool({ "path" => @csv, "filename" => "../../etc/r.csv" })
    assert_equal "r.csv", @uploads.fetch(0)[:filename]
  end

  def test_rejects_paths_outside_allowed_roots
    outside = File.join(@root, "secret.txt")
    File.write(outside, "x")
    out = run_tool({ "path" => outside, "filename" => "s.txt" })
    assert_match(/not inside an allowed upload directory/, out)
    assert_empty @uploads
  end

  def test_rejects_traversal_out_of_an_allowed_root
    File.write(File.join(@root, "secret.txt"), "x")
    out = run_tool({ "path" => File.join(@outputs, "..", "secret.txt"), "filename" => "s.txt" })
    assert_match(/not inside an allowed upload directory/, out)
    assert_empty @uploads
  end

  def test_rejects_symlink_pointing_outside
    target = File.join(@root, "secret.txt")
    File.write(target, "x")
    link = File.join(@outputs, "link.csv")
    File.symlink(target, link)
    out = run_tool({ "path" => link, "filename" => "l.csv" })
    assert_match(/not inside an allowed upload directory/, out)
    assert_empty @uploads
  end

  def test_rejects_sibling_dir_sharing_a_prefix
    evil = "#{@outputs}-evil"
    Dir.mkdir(evil)
    f = File.join(evil, "x.csv")
    File.write(f, "x")
    out = run_tool({ "path" => f, "filename" => "x.csv" })
    assert_match(/not inside an allowed upload directory/, out)
    assert_empty @uploads
  end

  def test_rejects_missing_file
    out = run_tool({ "path" => File.join(@outputs, "nope.csv"), "filename" => "n.csv" })
    assert_match(/no such file/, out)
  end

  def test_rejects_files_over_20mb
    big = File.join(@outputs, "big.csv")
    File.open(big, "wb") { |f| f.truncate(20 * 1024 * 1024 + 1) }
    out = run_tool({ "path" => big, "filename" => "big.csv" })
    assert_match(/limit/, out)
    assert_empty @uploads
  end

  def test_errors_without_a_slack_conversation
    assert_match(/no Slack conversation/, run_tool({ "path" => @csv, "filename" => "r.csv" }, slack: nil))
    assert_match(/no Slack conversation/, run_tool({ "path" => @csv, "filename" => "r.csv" }, slack: REPL))
    assert_empty @uploads
  end

  def test_repl_mode_prints_the_path_instead_of_uploading
    UploadTool.repl_mode = true
    out = nil
    assert_output(/slack_upload_file/) { out = run_tool({ "path" => @csv, "filename" => "r.csv" }, slack: REPL) }
    assert_match(/REPL mode/, out)
    assert_includes out, File.realpath(@csv)
    assert_empty @uploads
  end
end
