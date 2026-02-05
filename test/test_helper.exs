# Auto-exclude privileged tests when not running as root
# Run `sudo mix test` to include all tests
if System.get_env("USER") != "root" do
  ExUnit.configure(exclude: [:privileged])
end

ExUnit.start()
