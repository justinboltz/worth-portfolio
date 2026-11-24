# Hosted instances can keep their encryption keys in the provider's secret store.
# Local encrypted Rails credentials remain the fallback when these are unset.
{
  primary_key: "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY",
  deterministic_key: "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY",
  key_derivation_salt: "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"
}.each do |setting, variable|
  value = ENV[variable].presence
  Rails.application.config.active_record.encryption.public_send("#{setting}=", value) if value
end
