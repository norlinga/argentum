require 'set'

module Argentum
  # Single background thread that ingests one video at a time.
  module Worker
    QUEUE = Queue.new
    QUEUED = Set.new
    MUTEX = Mutex.new

    module_function

    def start
      Video.where(status: 'processing').update(status: 'pending') # interrupted by a restart
      Thread.new do
        loop do
          id = QUEUE.pop
          begin
            video = Video[id]
            Ingest.process(video) if video && %w[pending ready error].include?(video.status)
          rescue StandardError => e
            # Ingest records its own failures; this catches the rest (e.g. SQLite BUSY)
            # so one bad video can't stop the only worker thread.
            warn "argentum: ingest failed for video #{id}: #{e.class}: #{e.message}"
          ensure
            MUTEX.synchronize { QUEUED.delete(id) }
          end
        end
      end
    end

    def enqueue(id)
      MUTEX.synchronize { QUEUE << id if QUEUED.add?(id) }
    end

    def enqueue_pending
      Video.where(status: 'pending').select_map(:id).each { |id| enqueue(id) }
    end

    def reprocess_all
      active = Video.exclude(status: %w[missing ignored])
      active.update(error: nil)
      Video.where(status: 'error').update(status: 'pending')
      active.select_map(:id).each { |id| enqueue(id) }
    end

    # Videos queued or currently being worked on.
    def outstanding = MUTEX.synchronize { QUEUED.size }
  end
end
