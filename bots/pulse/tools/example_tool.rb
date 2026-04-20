# frozen_string_literal: true

class CurrentTimeTool < Grantclaw::Tool
  desc "Get the current date and time"

  def call
    Time.now.strftime("%A %B %d, %Y %I:%M %p %Z")
  end
end
