require 'find'
require 'set'

module Argentum
  # Walks the media dir, registers new files and flags changed or vanished ones.
  module Scanner
    LOCK = Mutex.new
    RESCAN = Mutex.new

    module_function

    def scan!
      return false unless LOCK.try_lock

      unsettled = false
      begin
        root = Config.media_dir
        seen = Set.new
        Find.find(root) do |path|
          Find.prune if File.basename(path).start_with?('.') && path != root
          next unless File.file?(path) && Config.extensions.include?(File.extname(path).downcase)

          rel = path.delete_prefix(root).delete_prefix('/')
          next unless Config.media_path(rel)

          seen << rel # present, even if still arriving: must not be marked missing
          stat = File.stat(path)
          if Config.settled?(stat)
            register(rel, stat)
          else
            unsettled = true
          end
        end
        Video.exclude(status: %w[missing ignored]).exclude(rel_path: seen.to_a).update(status: 'missing')
        Worker.enqueue_pending
      ensure
        LOCK.unlock
      end
      schedule_rescan if unsettled
      true
    end

    # Look again shortly, once files that are still being written have had time to
    # settle, instead of waiting for the next periodic scan. At most one is pending.
    def schedule_rescan(delay = Config.settle_seconds + 1)
      RESCAN.synchronize do
        return if @rescan&.alive?

        @rescan = Thread.new do
          sleep delay
          RESCAN.synchronize { @rescan = nil } # so this scan can schedule the next one
          Argentum.safely('settle rescan') { scan! }
        end
      end
    end

    def rescan_scheduled? = RESCAN.synchronize { !!@rescan&.alive? }

    def register(rel, stat)
      video = Video.first(rel_path: rel)
      return if video&.status == 'ignored' # removed by the user (e.g. a duplicate): never re-ingest

      if video.nil?
        video = Video.create(rel_path: rel, title: titleize(rel), size: stat.size, mtime: stat.mtime.to_i,
                             created_at: Time.now, status: 'pending')
        video.set_tags(File.dirname(rel).split('/').reject { |d| d == '.' }.map { |d| d.tr('_-', '  ') }.join(','))
      elsif video.size != stat.size || video.mtime != stat.mtime.to_i
        video.update(size: stat.size, mtime: stat.mtime.to_i, status: 'pending')
      elsif video.status == 'missing'
        video.update(status: File.exist?(Ingest.thumb_path(video.id)) ? 'ready' : 'pending')
      end
    end

    def titleize(rel)
      base = File.basename(rel, '.*').gsub(/[_\-.]+/, ' ').squeeze(' ').strip
      base.empty? ? rel : base[0].upcase + base[1..]
    end
  end
end
