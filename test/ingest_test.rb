require 'test_helper'

module Argentum
  # End-to-end ingest against real (tiny, generated) media. Slower than the rest
  # of the suite, but this is the pipeline everything else depends on.
  class IngestTest < TestCase
    def setup
      super
      require_ffmpeg!
    end

    def ingest(fixture, rel = File.basename(fixture))
      add_media(rel, from: Fixtures.path(fixture))
      Scanner.scan!
      v = Video.first(rel_path: rel)
      Ingest.process(v)
      v.reload
    end

    def test_h264_source_is_remuxed_into_a_ready_video_with_all_assets
      v = ingest('h264.mp4')

      assert_equal 'ready', v.status, v.error
      assert v.hls_ready
      assert_in_delta 4.0, v.duration, 0.2
      assert_equal [320, 240, 'h264', 'aac'], [v.width, v.height, v.vcodec, v.acodec]
      refute_nil v.ingested_at

      assert_equal 3, Ingest.still_count(v.id) # 4s → minimum of 3 stills
      assert_equal 1, v.thumb_index
      assert_equal File.binread(Ingest.still_path(v.id, 1)), File.binread(Ingest.thumb_path(v.id))
      assert File.size?(Ingest.preview_path(v.id))
      assert_equal 3, v.fingerprint.split.size
      v.fingerprint.split.each { |h| assert_match(/\A\h{16}\z/, h) }

      playlist = File.read(File.join(Ingest.hls_path(v.id), 'index.m3u8'))
      assert_includes playlist, '#EXT-X-PLAYLIST-TYPE:VOD'
      assert_includes playlist, 'seg00000.ts'
      refute Dir.exist?("#{Ingest.hls_path(v.id)}.tmp"), 'temp dir is renamed into place'
      assert_equal 'h264', probe_codec(File.join(Ingest.hls_path(v.id), 'seg00000.ts'))
    end

    def test_non_browser_codec_is_transcoded_to_h264
      v = ingest('reencode.mkv')
      assert_equal 'ready', v.status, v.error
      assert_equal 'mpeg4', v.vcodec
      assert_equal 'h264', probe_codec(File.join(Ingest.hls_path(v.id), 'seg00000.ts'))
    end

    def test_h264_with_mp3_audio_copies_video_and_converts_only_audio
      commands = []
      real = Ingest.method(:run)
      hook = ->(cmd) { commands << cmd; real.call(cmd) }
      v = Ingest.stub(:run, hook) { ingest('h264_mp3.mkv') }
      assert_equal 'ready', v.status, v.error
      cmd = commands.find { |args| args.include?('hls') }
      assert_equal 'copy', cmd[cmd.index('-c:v') + 1]
      assert_equal 'aac', cmd[cmd.index('-c:a') + 1]
      streams = Ingest.probe(File.join(Ingest.hls_path(v.id), 'seg00000.ts'))['streams']
      assert_equal %w[h264 aac], streams.map { |s| s['codec_name'] }
    end

    def test_preview_is_playable_and_failed_replacement_preserves_previous_clip
      v = ingest('h264.mp4')
      path = Ingest.preview_path(v.id)
      info = Ingest.probe(path)
      assert_equal ['h264'], info['streams'].map { |s| s['codec_name'] }
      assert_in_delta 3.0, info['format']['duration'].to_f, 0.3
      previous = File.binread(path)
      real = Ingest.method(:run)
      hook = lambda do |cmd|
        raise Ingest::Error, 'preview disk full' if cmd.include?('concat')

        real.call(cmd)
      end
      Ingest.stub(:run, hook) { Ingest.process(v) }
      assert_equal ['ready', 'preview disk full'], [v.reload.status, v.error]
      assert_equal previous, File.binread(path)
      assert_empty Dir.glob(File.join(Config.previews_dir, '*-preview-*'))
    end

    def test_source_changed_during_ingest_waits_for_it_to_settle
      add_media('a.mp4', from: Fixtures.path('h264.mp4'))
      Scanner.scan!
      v = Video.first
      Worker::QUEUED.clear # queued by the scan above; only what process does matters here
      real = Ingest.method(:make_hls)
      hook = lambda do |*args|
        real.call(*args)
        File.utime(Time.now, Time.now + 10, v.abs_path) # still being written
      end
      rescans = 0
      Scanner.stub(:schedule_rescan, -> { rescans += 1 }) do
        Ingest.stub(:make_hls, hook) { Ingest.process(v) }
      end
      assert_equal 'pending', v.reload.status, 'stale assets are not published as ready'
      assert_equal File.mtime(v.abs_path).to_i, v.mtime
      assert_equal 1, rescans, 'the scanner looks again once the file is quiet'
      assert_empty queued_ids, 'not retried immediately while the file is still changing'
    end

    def test_unsettled_source_is_deferred_without_running_ffmpeg
      add_media('arriving.mp4', from: Fixtures.path('h264.mp4'))
      v = create_video(rel_path: 'arriving.mp4', status: 'pending')
      ran = []
      rescans = 0
      with_env('ARGENTUM_SETTLE_SECONDS' => '60') do
        Scanner.stub(:schedule_rescan, -> { rescans += 1 }) do
          Ingest.stub(:run, ->(cmd) { ran << cmd }) { Ingest.process(v) }
        end
      end
      assert_empty ran
      assert_equal ['pending', 1], [v.reload.status, rescans]
    end

    def test_unsettled_source_of_a_ready_video_keeps_it_ready
      v = ingest('h264.mp4')
      File.utime(Time.now, Time.now, v.abs_path)
      with_env('ARGENTUM_SETTLE_SECONDS' => '60') do
        Scanner.stub(:schedule_rescan, -> {}) { Ingest.process(v) }
      end
      assert_equal 'ready', v.reload.status
    end

    def test_failed_ingest_after_duplicate_removal_purges_partial_assets
      add_media('a.mp4', from: Fixtures.path('h264.mp4'))
      Scanner.scan!
      v = Video.first
      hook = lambda do |*|
        Dedupe.remove!([v.id])
        File.write(Ingest.preview_path(v.id), 'partial')
        raise Ingest::Error, 'removed during ingest'
      end
      Ingest.stub(:make_hls, hook) { Ingest.process(v) }
      assert_equal 'ignored', v.reload.status
      refute File.exist?(Ingest.preview_path(v.id))
    end

    def test_reprocessing_keeps_chosen_thumbnail_and_stays_ready_throughout
      v = ingest('h264.mp4')
      Ingest.choose_thumbnail(v, 2)
      statuses = []
      real = Ingest.method(:run)
      hook = ->(cmd) { statuses << v.reload.status; real.call(cmd) }
      Ingest.stub(:run, hook) { Ingest.process(v) }
      assert_equal ['ready'], statuses.uniq, 'never flips to processing while already playable'
      assert_equal 2, v.reload.thumb_index
      assert_equal File.binread(Ingest.still_path(v.id, 2)), File.binread(Ingest.thumb_path(v.id))
    end

    # e.g. the data volume fills up during "Reprocess all": the library must not empty out.
    def test_failed_reprocess_keeps_a_ready_video_playable
      v = ingest('h264.mp4')
      playlist = File.join(Ingest.hls_path(v.id), 'index.m3u8')
      old_playlist = File.read(playlist)
      old_thumb = File.binread(Ingest.thumb_path(v.id))

      with_failing_hls { Ingest.process(v) }

      v.reload
      assert_equal 'ready', v.status
      assert v.hls_ready
      assert_equal 'ffmpeg failed: No space left on device', v.error
      assert_equal old_playlist, File.read(playlist), 'previous HLS left intact'
      assert_equal old_thumb, File.binread(Ingest.thumb_path(v.id))
      refute Dir.exist?("#{Ingest.hls_path(v.id)}.tmp"), 'partial segments cleaned up'
      assert_includes Video.ready.search.select_map(:id), v.id, 'still listed in the library'
    end

    def test_failed_hls_directory_swap_restores_previous_playable_assets
      v = ingest('h264.mp4')
      playlist = File.join(Ingest.hls_path(v.id), 'index.m3u8')
      previous = File.binread(playlist)
      real = File.method(:rename)
      hook = lambda do |src, dest|
        raise Errno::ENOSPC if src == Ingest.hls_path(v.id) + '.tmp'

        real.call(src, dest)
      end
      File.stub(:rename, hook) { Ingest.process(v) }
      assert_equal 'ready', v.reload.status
      assert_includes v.error, 'No space left on device'
      assert_equal previous, File.binread(playlist)
      refute Dir.exist?(Ingest.hls_path(v.id) + '.previous')
      refute Dir.exist?(Ingest.hls_path(v.id) + '.tmp')
    end

    def test_failed_still_generation_preserves_previous_thumbnail_choices
      v = ingest('h264.mp4')
      previous = File.binread(Ingest.still_path(v.id, 1))
      real = Ingest.method(:run)
      hook = lambda do |cmd|
        raise Ingest::Error, 'stills disk full' if cmd.include?('-frames:v')

        real.call(cmd)
      end
      Ingest.stub(:run, hook) { Ingest.process(v) }
      assert_equal 'ready', v.reload.status
      assert_equal previous, File.binread(Ingest.still_path(v.id, 1))
      assert_empty Dir.glob(File.join(Config.stills_dir, '*-stills-*'))
    end

    def test_successful_reprocess_clears_previous_failure
      v = ingest('h264.mp4')
      with_failing_hls { Ingest.process(v) }
      Ingest.process(v.reload)
      assert_equal ['ready', nil], [v.reload.status, v.error]
    end

    def test_failed_first_ingest_is_still_an_error
      add_media('a.mp4', from: Fixtures.path('h264.mp4'))
      Scanner.scan!
      v = Video.first
      with_failing_hls { Ingest.process(v) }
      assert_equal 'error', v.reload.status
      refute Dir.exist?("#{Ingest.hls_path(v.id)}.tmp")
    end

    def test_ready_video_whose_source_vanished_becomes_an_error
      v = ingest('h264.mp4')
      File.delete(v.abs_path)
      Ingest.process(v)
      assert_equal ['error', 'file not found'], [v.reload.status, v.error]
    end

    def test_missing_source_file_is_an_error
      v = create_video(status: 'pending', rel_path: 'gone.mp4')
      Ingest.process(v)
      assert_equal ['error', 'file not found'], [v.reload.status, v.error]
    end

    def test_file_without_video_stream_is_an_error
      v = ingest('audio_only.m4a', 'song.mp4')
      assert_equal ['error', 'no video stream'], [v.status, v.error]
    end

    def test_corrupt_file_is_an_error_with_ffprobe_message
      add_media('broken.mp4', content: Random.bytes(4096))
      Scanner.scan!
      v = Video.first
      Ingest.process(v)
      v.reload
      assert_equal 'error', v.status
      assert_match(/\Affprobe failed/, v.error)
      assert_operator v.error.size, :<=, 500
    end

    def test_video_removed_as_duplicate_mid_ingest_is_discarded
      add_media('a.mp4', from: Fixtures.path('h264.mp4'))
      Scanner.scan!
      v = Video.first
      # Simulate the user removing it from /duplicates while ffmpeg is building HLS.
      real = Ingest.method(:make_hls)
      hook = lambda do |*args|
        real.call(*args)
        Video.where(id: v.id).update(status: 'ignored')
      end
      Ingest.stub(:make_hls, hook) { Ingest.process(v) }

      assert_equal 'ignored', v.reload.status
      refute File.exist?(Ingest.thumb_path(v.id))
      refute Dir.exist?(Ingest.hls_path(v.id))
      refute Dir.exist?(Ingest.stills_dir(v.id))
    end

    def test_choose_thumbnail_rejects_unknown_still
      v = create_video
      assert_raises(Ingest::Error) { Ingest.choose_thumbnail(v, 7) }
    end

    def test_reencode_is_detected_as_duplicate_but_different_footage_is_not
      a = ingest('h264.mp4', 'original.mp4')
      b = ingest('reencode.mkv', 'copy.mkv')
      c = ingest('other.mp4', 'different.mp4')
      assert_equal %w[ready ready ready], [a, b, c].map(&:status)

      groups = Dedupe.groups.map { |g| g.map(&:id) }
      assert_equal [[a.id, b.id]], groups, 'higher resolution h264 copy is the suggested keeper'
    end

    private

    # Let every ffmpeg step run for real except HLS, which writes a partial segment and dies.
    def with_failing_hls(&)
      real = Ingest.method(:run)
      fake = lambda do |cmd|
        return real.call(cmd) unless cmd.include?('hls')

        File.write(cmd.last.sub('index.m3u8', 'seg00000.ts'), 'partial')
        raise Ingest::Error, 'ffmpeg failed: No space left on device'
      end
      Ingest.stub(:run, fake, &)
    end

    def probe_codec(path)
      Ingest.probe(path)['streams'].find { |s| s['codec_type'] == 'video' }['codec_name']
    end
  end
end
