require 'open3'
require 'json'
require 'fileutils'
require 'tmpdir'

module Argentum
  # Turns a pending Video row into a ready one: probe, static thumbnail,
  # motion preview and HLS (m3u8) segments.
  module Ingest
    class Error < StandardError; end

    SEGMENT_SECONDS = 6
    STILL_COUNT = 12

    module_function

    # Every outcome is recorded through #conclude, so a duplicate removed (or a file
    # gone missing) while we worked is never overwritten. Returns nothing useful.
    def process(video)
      # Already-ready videos stay visible (and playable) while being regenerated.
      was_ready = video.ready?
      unless was_ready
        return unless active(video).update(status: 'processing', error: nil).positive?

        video.refresh
      end
      src = video.abs_path
      raise Error, 'file not found' unless src && File.file?(src)

      before = File.stat(src)
      return defer(video, was_ready, before) unless Config.settled?(before)

      generate(video, src)
      after = File.stat(src)
      # Written to while we worked: what we made is stale. Try again once it settles.
      return defer(video, false, after) if after.size != before.size || after.mtime != before.mtime

      conclude(video, status: 'ready', hls_ready: true, error: nil, ingested_at: Time.now,
                      size: after.size, mtime: after.mtime.to_i)
    rescue StandardError => e
      # A failed regeneration (e.g. data volume full during "Reprocess all") leaves the
      # previous HLS and thumbnail in place, so keep the video playable and just note why.
      # Only a vanished source makes a previously-ready video unplayable.
      keep_ready = was_ready && src && File.file?(src)
      conclude(video, status: keep_ready ? 'ready' : 'error', error: e.message[0, 500])
    end

    # Probe the source and (re)build stills, fingerprint, preview and HLS.
    def generate(video, src)
      info = probe(src)
      vs = info['streams'].find { |s| s['codec_type'] == 'video' && s.dig('disposition', 'attached_pic') != 1 }
      as = info['streams'].find { |s| s['codec_type'] == 'audio' }
      raise Error, 'no video stream' unless vs

      duration = info.dig('format', 'duration').to_f
      video.update(duration: duration, width: vs['width'], height: vs['height'],
                   vcodec: vs['codec_name'], acodec: as && as['codec_name'])

      make_stills(video, src, duration, vs.fetch('index'))
      video.update(fingerprint: Dedupe.fingerprint(video.id) || '')
      make_preview(video, src, duration, vs.fetch('index'))
      make_hls(video, src, vs, as)
    end

    # The source is still being written. Leave it pending (a ready video keeps its
    # current assets) and let the scanner's settle rescan queue it again.
    def defer(video, keep_ready, stat)
      conclude(video, status: 'pending', size: stat.size, mtime: stat.mtime.to_i) unless keep_ready
      Scanner.schedule_rescan
    end

    # Record an outcome unless the video was removed or went missing meanwhile; a
    # removed duplicate's freshly generated assets are discarded instead.
    def conclude(video, **attrs)
      return if active(video).update(attrs).positive?

      Dedupe.purge_assets(video.id) if Video.where(id: video.id).get(:status) == 'ignored'
    end

    def active(video) = Video.where(id: video.id).exclude(status: %w[ignored missing])

    def probe(path)
      out = run(%w[ffprobe -v error -print_format json -show_format -show_streams] + [path])
      JSON.parse(out)
    end

    def thumb_path(id)   = File.join(Config.thumbs_dir, "#{id}.jpg")
    def preview_path(id) = File.join(Config.previews_dir, "#{id}.mp4")
    def hls_path(id)     = File.join(Config.hls_dir, id.to_s)

    def stills_dir(id) = File.join(Config.stills_dir, id.to_s)
    def still_path(id, n) = File.join(stills_dir(id), format('%02d.jpg', n))
    def still_count(id) = Dir.glob(File.join(stills_dir(id), '*.jpg')).size

    # Evenly spaced candidate stills; the chosen one is copied to thumbs/<id>.jpg.
    def make_stills(video, src, duration, stream_index = 0)
      n = duration.positive? ? [[(duration / 3).floor, 3].max, STILL_COUNT].min : 1
      dir = stills_dir(video.id)
      tmp = Dir.mktmpdir("#{video.id}-stills-", Config.stills_dir)
      n.times do |i|
        at = duration.positive? ? duration * (i + 0.5) / n : 0
        run(ffmpeg_args + %W[-ss #{at}] + input_args(src) +
            %W[-map 0:#{stream_index} -frames:v 1 -vf scale=640:-2
               -threads #{Config.ffmpeg_threads} -q:v 3 #{File.join(tmp, format('%02d.jpg', i))}])
      end
      replace_directory(tmp, dir)
      choose_thumbnail(video, video.thumb_index && video.thumb_index < n ? video.thumb_index : [1, n - 1].min)
    ensure
      FileUtils.rm_rf(tmp) if tmp
    end

    def choose_thumbnail(video, index)
      src = still_path(video.id, index)
      raise Error, 'no such still' unless File.file?(src)

      Dir.mktmpdir("#{video.id}-thumb-", Config.thumbs_dir) do |dir|
        tmp = File.join(dir, 'thumb.jpg')
        FileUtils.cp(src, tmp)
        File.rename(tmp, thumb_path(video.id))
      end
      video.update(thumb_index: index)
    end

    # A short silent clip stitched from evenly spaced 1s samples across the video.
    def make_preview(video, src, duration, stream_index = 0)
      n = duration < 8 ? 3 : 8
      clip = [1.0, duration / n].min
      starts = (0...n).map { |i| [duration * (i + 0.5) / n - clip / 2, 0].max.round(2) }
      # One decoder at a time: eight simultaneous high-resolution inputs can
      # exhaust a small machine's RAM even though the preview itself is tiny.
      Dir.mktmpdir("#{video.id}-preview-", Config.previews_dir) do |dir|
        starts.each_with_index do |at, i|
          run(ffmpeg_args + %W[-ss #{at} -t #{clip}] + input_args(src) +
              %W[-map 0:#{stream_index} -an -vf fps=24,scale=360:-2,setsar=1 -c:v libx264
                 -threads #{Config.ffmpeg_threads} -preset veryfast -crf 30 -pix_fmt yuv420p
                 #{File.join(dir, "#{i}.mp4")}])
        end
        list = File.join(dir, 'clips.txt')
        File.write(list, starts.each_index.map { |i| "file '#{i}.mp4'\n" }.join)
        output = File.join(dir, 'preview.mp4')
        run(ffmpeg_args + %W[-f concat -safe 1 -i #{list} -c copy -movflags +faststart #{output}])
        File.rename(output, preview_path(video.id))
      end
    end

    # Remux (no re-encode) when the streams are already browser-friendly, else transcode.
    def make_hls(video, src, vs, as)
      copyable = vs['codec_name'] == 'h264' && vs['pix_fmt'] == 'yuv420p'
      codec = if copyable
                %w[-c:v copy]
              else
                %W[-c:v libx264 -preset veryfast -crf 22 -pix_fmt yuv420p
                   -force_key_frames expr:gte(t,n_forced*#{SEGMENT_SECONDS})]
              end
      codec += as.nil? || as['codec_name'] == 'aac' ? %w[-c:a copy] : %w[-c:a aac -b:a 160k]
      tmp = hls_path(video.id) + '.tmp'
      FileUtils.rm_rf(tmp)
      FileUtils.mkdir_p(tmp)
      streams = ['-map', "0:#{vs.fetch('index')}"]
      streams += ['-map', "0:#{as.fetch('index')}"] if as
      run(ffmpeg_args + input_args(src) + streams + %w[-sn -dn] + codec +
          %W[-threads #{Config.ffmpeg_threads}] +
          %W[-f hls -hls_time #{SEGMENT_SECONDS} -hls_playlist_type vod
             -hls_segment_filename #{File.join(tmp, 'seg%05d.ts')} #{File.join(tmp, 'index.m3u8')}])
      replace_directory(tmp, hls_path(video.id))
    ensure
      FileUtils.rm_rf(tmp) if tmp # half-written segments from a failed run (no-op after the rename)
    end

    # Keep the previous assets until the replacement succeeds. Recover a backup
    # left by an interrupted swap before attempting another replacement.
    def replace_directory(tmp, destination)
      previous = destination + '.previous'
      File.rename(previous, destination) if File.directory?(previous) && !File.exist?(destination)
      FileUtils.rm_rf(previous)
      File.rename(destination, previous) if File.exist?(destination)
      begin
        File.rename(tmp, destination)
      rescue StandardError
        File.rename(previous, destination) if File.directory?(previous) && !File.exist?(destination)
        raise
      end
      FileUtils.rm_rf(previous)
    end

    def ffmpeg_args
      %W[ffmpeg -nostdin -y -v error -filter_threads #{Config.ffmpeg_threads}
         -filter_complex_threads #{Config.ffmpeg_threads}]
    end

    def input_args(src) = %W[-threads #{Config.ffmpeg_threads} -i #{src}]

    def run(cmd)
      out, err, status = Open3.capture3(*cmd.map(&:to_s))
      raise Error, "#{cmd.first} failed: #{err.lines.last(4).join.strip}" unless status.success?

      out
    end
  end
end
