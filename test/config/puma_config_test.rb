require "test_helper"
require "puma/configuration"

# config/puma.rb runs Solid Queue inside Puma. In production it must use the
# async (threaded) mode: fork mode spends ~180 MB on three idle processes.
class PumaConfigTest < ActiveSupport::TestCase
  def load_puma_config(env)
    original = env.keys.index_with { |k| ENV[k] }
    env.each { |k, v| ENV[k] = v }
    config = Puma::Configuration.new({}, {}, ENV.to_h) { |user| user.load Rails.root.join("config/puma.rb").to_s }
    config.clamp
    config.options
  ensure
    original.each { |k, v| ENV[k] = v }
  end

  test "Solid Queue runs as threads inside Puma by default" do
    options = load_puma_config("SOLID_QUEUE_IN_PUMA" => "true", "SOLID_QUEUE_MODE" => nil)
    assert_equal :async, options[:solid_queue_mode]
  end

  test "SOLID_QUEUE_MODE=fork switches back without a code change" do
    options = load_puma_config("SOLID_QUEUE_IN_PUMA" => "true", "SOLID_QUEUE_MODE" => "fork")
    assert_equal :fork, options[:solid_queue_mode]
  end

  test "production DB pool covers web threads plus job threads" do
    deploy = YAML.load_file(Rails.root.join("config/deploy.yml"))
    env = deploy.dig("env", "clear")
    job_threads = YAML.load(ERB.new(File.read(Rails.root.join("config/queue.yml"))).result, aliases: true).dig("production", "workers", 0, "threads")

    assert_operator env["DB_POOL"].to_i, :>=, env["RAILS_MAX_THREADS"].to_i + job_threads + 2,
                    "web + job threads + dispatcher/heartbeat must fit in one pool"
  end
end
