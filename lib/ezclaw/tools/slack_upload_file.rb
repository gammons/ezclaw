# frozen_string_literal: true

require "tmpdir"

module Ezclaw
  module Tools
    class SlackUploadFileTool < Tool
      desc "Upload a file (e.g. a CSV report) into the Slack thread you are replying in. " \
           "It always goes to the current conversation's thread and cannot post anywhere else. " \
           "Only files under the bot's outputs directory or the temp directory can be uploaded, up to 20 MB."
      param :path, type: :string, desc: "Path of the file on this server", required: true
      param :filename, type: :string, desc: "Name for the file in Slack, e.g. adp-engaged-advocates-2026-10-23.csv", required: true
      param :title, type: :string, desc: "Title shown above the file (defaults to the filename)"
      param :comment, type: :string, desc: "Message posted with the file: what it is, what's counted, caveats"

      MAX_BYTES = 20 * 1024 * 1024

      class << self
        attr_accessor :slack_client, :repl_mode
        attr_writer :allowed_roots

        def allowed_roots
          @allowed_roots || [Dir.tmpdir]
        end
      end

      def call(path:, filename:, title: nil, comment: nil)
        return "Error: no such file: #{path}" unless File.file?(path.to_s)

        real = allowed_realpath(path.to_s)
        unless real
          return "Error: #{path} is not inside an allowed upload directory (#{self.class.allowed_roots.join(', ')})"
        end

        size = File.size(real)
        return "Error: file is #{size} bytes; the limit is #{MAX_BYTES} bytes" if size > MAX_BYTES

        name = File.basename(filename.to_s)

        if self.class.repl_mode
          puts "[slack_upload_file] #{name} (#{size} bytes) at #{real}"
          puts "[slack_upload_file] comment: #{comment}" if comment
          return "File not uploaded (REPL mode). It is at #{real}."
        end

        # The destination always comes from the message being handled, never
        # from the model, so a file can't be sent to another channel.
        slack = SlackContext.current
        unless slack && slack[:channel] && slack[:thread_ts]
          return "Error: no Slack conversation to upload into (this only works when replying in Slack)"
        end

        client = self.class.slack_client
        return "Error: Slack client not configured" unless client

        params = {
          channel_id: slack[:channel],
          thread_ts: slack[:thread_ts],
          filename: name,
          title: title.to_s.strip.empty? ? name : title,
          content: File.binread(real)
        }
        params[:initial_comment] = SlackFormatter.markdown_to_mrkdwn(comment) unless comment.to_s.strip.empty?
        client.files_upload_v2(params)
        "Uploaded #{name} to the thread."
      end

      private

      # Resolve symlinks and ".." first, then require the result to sit inside
      # an allowed root (as a directory prefix, so "outputs-evil" doesn't match
      # "outputs").
      def allowed_realpath(path)
        real = File.realpath(path)
        roots = self.class.allowed_roots.filter_map do |r|
          File.realpath(r)
        rescue Errno::ENOENT
          nil
        end
        roots.any? { |root| real.start_with?(root.end_with?("/") ? root : "#{root}/") } ? real : nil
      rescue Errno::ENOENT, Errno::EACCES
        nil
      end
    end
  end
end
