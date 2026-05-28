# Azure Flex PostgreSQL enforces an `azure.extensions` server-parameter
# allow-list and rejects `CREATE EXTENSION plpgsql` for non-`azuresu` users —
# even though plpgsql is installed by default in every PostgreSQL database.
#
# This makes `db:schema:load` fail on a fresh Azure-hosted DB because the
# generated `db/schema.rb` opens with `enable_extension "plpgsql"`.
#
# We can't (and shouldn't) widen the allow-list just for a no-op; instead, we
# patch ActiveRecord so `enable_extension "plpgsql"` is a silent no-op. Other
# extensions still flow through normally. See SRE-3139.
module SkipPlpgsqlEnableExtension
  def enable_extension(name, **options)
    return if name.to_s == "plpgsql"
    super
  end
end

ActiveSupport.on_load(:active_record) do
  ActiveRecord::ConnectionAdapters::AbstractAdapter.prepend(SkipPlpgsqlEnableExtension)
end
