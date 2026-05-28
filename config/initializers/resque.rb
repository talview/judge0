Resque.redis = Redis.new(
  host:     ENV["REDIS_HOST"],
  port:     ENV["REDIS_PORT"],
  password: ENV["REDIS_PASSWORD"],
  db:       ENV.fetch("REDIS_DB", "0").to_i,
  thread_safe: true
)
