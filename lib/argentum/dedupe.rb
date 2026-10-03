require 'open3'
require 'fileutils'

module Argentum
  # Finds videos that are different encodings of the same footage, and lets the
  # user retire the extra copies. Files on disk are never touched: a removed copy
  # is marked "ignored" so the scanner and worker leave it alone, and its
  # generated assets (stills, preview, HLS) are deleted to free space.
  #
  # Matching: stills are taken at the same relative points in every video, so two
  # encodings of the same footage have near-identical stills. Each still gets a
  # 64-bit difference hash (dHash); videos with matching durations whose stills'
  # median Hamming distance is small are grouped together.
  module Dedupe
    MAX_DISTANCE = 10 # of 64 bits, median across stills
    LOCK = Mutex.new

    module_function

    # Space-separated hex dHash per still, in still order.
    def fingerprint(id)
      dir = Ingest.stills_dir(id)
      return nil if Ingest.still_count(id).zero?

      out, _err, status = Open3.capture3(*(Ingest.ffmpeg_args + Ingest.input_args(File.join(dir, '%02d.jpg')) +
                                         %W[-vf scale=9:8:flags=area,format=gray -threads #{Config.ffmpeg_threads}
                                            -f rawvideo -]),
                                         binmode: true)
      return nil unless status.success? && !out.empty?

      out.bytes.each_slice(72).select { |px| px.size == 72 }.map do |px|
        bits = 0
        8.times { |r| 8.times { |c| bits = (bits << 1) | (px[r * 9 + c] > px[r * 9 + c + 1] ? 1 : 0) } }
        format('%016x', bits)
      end.join(' ')
    end

    def unfingerprinted = Video.ready.where(fingerprint: nil)

    # Fill in fingerprints for videos ingested before fingerprinting existed.
    # Materialise the ids first: writing while a SELECT cursor is still open keeps
    # SQLite in a stale read transaction, and the upgrade to a write fails with
    # BUSY (no busy-wait) as soon as the ingest worker commits anything.
    def backfill!
      return false unless LOCK.try_lock

      begin
        unfingerprinted.select_map(:id).each do |id|
          # '' = nothing to compare (no stills); marks it done so we don't retry on every visit.
          Video.where(id: id).update(fingerprint: fingerprint(id) || '')
        rescue StandardError => e
          warn "argentum: fingerprint failed for video #{id}: #{e.message}"
        end
      ensure
        LOCK.unlock
      end
      true
    end

    def backfilling? = LOCK.locked?

    # Groups (arrays of Videos, 2+) that look like the same footage.
    def groups
      vids = Video.ready.exclude(fingerprint: nil).exclude(duration: nil).order(:duration).all
      hashes = vids.to_h { |v| [v.id, v.fingerprint.split.map { |h| h.to_i(16) }] }
      dismissed = DB[:dupe_dismissals].select_map(%i[a_id b_id]).to_set
      grouped = Set.new

      # Each member must match the group's anchor directly — no chaining, so a
      # run of similar-but-distinct clips can't snowball into one big group.
      groups = vids.each_with_index.filter_map do |a, i|
        next if grouped.include?(a.id)

        members = [a]
        ((i + 1)...vids.size).each do |j|
          b = vids[j]
          break if b.duration - a.duration > duration_tolerance(a.duration)
          next if grouped.include?(b.id) || dismissed.include?([a.id, b.id].minmax)
          next unless similar?(hashes[a.id], hashes[b.id])

          members << b
        end
        next if members.size < 2

        grouped.merge(members.map(&:id))
        members
      end
      groups.map { |g| g.sort_by { |v| keeper_rank(v) } }.sort_by { |g| -g.first.duration }
    end

    # Re-encodes of the same footage land within a fraction of a second of each other.
    def duration_tolerance(seconds) = [0.75, seconds * 0.002].max

    # Compare each still of `a` with the still at the same relative position in `b`.
    def similar?(a, b)
      return false if a.empty? || b.empty?

      dists = a.each_with_index.map do |h, i|
        j = (((i + 0.5) / a.size) * b.size - 0.5).round.clamp(0, b.size - 1)
        (h ^ b[j]).to_s(2).count('1')
      end.sort
      dists[dists.size / 2] <= MAX_DISTANCE
    end

    # Suggested copy to keep sorts first: most pixels, then browser-friendly codec, then largest file.
    def keeper_rank(v)
      [-(v.width.to_i * v.height.to_i), v.vcodec == 'h264' ? 0 : 1, -v.size.to_i, v.id]
    end

    def remove!(ids)
      Video.where(id: ids).exclude(status: 'ignored').all.each do |v|
        v.update(status: 'ignored', hls_ready: false)
        purge_assets(v.id)
      end
    end

    def restore!(video)
      return unless video.status == 'ignored'

      video.update(status: 'pending', fingerprint: nil, error: nil)
      Worker.enqueue(video.id)
    end

    def dismiss!(ids)
      ids.combination(2).each do |a, b|
        DB[:dupe_dismissals].insert_conflict.insert(a_id: [a, b].min, b_id: [a, b].max)
      end
    end

    def purge_assets(id)
      FileUtils.rm_f([Ingest.thumb_path(id), Ingest.preview_path(id)])
      FileUtils.rm_rf([Ingest.stills_dir(id), Ingest.stills_dir(id) + '.previous',
                       Ingest.hls_path(id), Ingest.hls_path(id) + '.tmp', Ingest.hls_path(id) + '.previous'])
    end
  end
end
