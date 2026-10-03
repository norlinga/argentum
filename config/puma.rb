# The ingest worker lives inside the web process, so stay single-process.
workers 0
threads 2, 8
bind "tcp://0.0.0.0:#{ENV.fetch('PORT', '4567')}"
environment ENV.fetch('APP_ENV', 'production')
