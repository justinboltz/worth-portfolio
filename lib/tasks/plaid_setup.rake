require "io/console"
require "securerandom"
require "yaml"

namespace :plaid do
  desc "Configure local encrypted credentials for Plaid Trial (live Production data)"
  task configure: :environment do
    abort "Run this task locally in development." unless Rails.env.development?
    abort "Run this command in an interactive terminal." unless $stdin.tty?

    print "Plaid client ID: "
    client_id = $stdin.gets.to_s.strip
    print "Plaid Production secret (hidden): "
    secret = $stdin.noecho(&:gets).to_s.strip
    puts
    abort "Both values are required; credentials were not changed." if client_id.empty? || secret.empty?

    credentials = Rails.application.credentials
    data = YAML.safe_load(credentials.read, permitted_classes: [Symbol], aliases: true) || {}
    data["plaid"] = { "client_id" => client_id, "secret" => secret, "env" => "production" }
    data["active_record_encryption"] ||= {
      "primary_key" => SecureRandom.hex(32),
      "deterministic_key" => SecureRandom.hex(32),
      "key_derivation_salt" => SecureRandom.hex(32)
    }
    credentials.write(data.to_yaml)
    puts "Encrypted credentials saved. Restart Rails. Keep config/master.key backed up privately."
  end
end
