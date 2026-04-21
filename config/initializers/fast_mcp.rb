# frozen_string_literal: true

# FastMcp - Model Context Protocol for Rails
# This initializer sets up the MCP middleware in your Rails application.
#
# In Rails applications, you can use:
# - ActionTool::Base as an alias for FastMcp::Tool
# - ActionResource::Base as an alias for FastMcp::Resource
#
# All your tools should inherit from ApplicationTool which already uses ActionTool::Base,
# and all your resources should inherit from ApplicationResource which uses ActionResource::Base.

# Mount the MCP middleware in your Rails application
# You can customize the options below to fit your needs.
require 'fast_mcp'

FastMcp.mount_in_rails(
  Rails.application,
  name: "smarts",
  version: "0.1.0",
  path_prefix: "/mcp",
  messages_route: "messages",
  sse_route: "sse",
  allowed_origins: [ "localhost", "127.0.0.1", "[::1]", "smarts.md", "mcp.smarts.md", /.*\.smarts\.md/ ],
  localhost_only: Rails.env.local?
  # In production, also enable:
  # authenticate: true,
  # auth_token: Rails.application.credentials.dig(:mcp, :auth_token)
) do |server|
  Rails.application.config.after_initialize do
    # FastMcp will automatically discover and register:
    # - All classes that inherit from ApplicationTool (which uses ActionTool::Base)
    # - All classes that inherit from ApplicationResource (which uses ActionResource::Base)
    server.register_tools(*ApplicationTool.descendants)
    server.register_resources(*ApplicationResource.descendants)
    # alternatively, you can register tools and resources manually:
    # server.register_tool(MyTool)
    # server.register_resource(MyResource)
  end
end
