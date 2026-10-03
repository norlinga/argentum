require 'argentum/config'
require 'argentum/db'
require 'argentum/models'
require 'argentum/ingest'
require 'argentum/dedupe'
require 'argentum/scanner'
require 'argentum/worker'
require 'argentum/app'

module Argentum
  # Start the background ingest worker, an initial scan and the periodic rescan.
  def self.boot!
    Config.validate!
    Worker.start
    Thread.new do
      safely('initial scan') { Scanner.scan! }
      safely('fingerprint backfill') { Dedupe.backfill! } # videos ingested before duplicate detection existed
    end
    interval = Config.scan_interval
    if interval.positive?
      Thread.new do
        loop do
          sleep interval
          safely('scan') { Scanner.scan! } # e.g. media dir briefly unmounted: try again next time
        end
      end
    end
  end

  # Background threads die on an unhandled exception; log it instead and carry on.
  def self.safely(what)
    yield
  rescue StandardError => e
    warn "argentum: #{what} failed: #{e.class}: #{e.message}"
  end
end
