require 'test_helper'

module Argentum
  class DedupeTest < TestCase
    A = 0x0f0f_0f0f_0f0f_0f0f
    B = 0x3c3c_3c3c_3c3c_3c3c # 32 bits away from A
    C = 0x5555_aaaa_5555_aaaa

    def fp(*hashes) = hashes.map { |h| format('%016x', h) }.join(' ')

    # Flip the lowest `n` bits.
    def near(h, n) = h ^ ((1 << n) - 1)

    def dupe(duration: 60.0, hashes: [A, B, C], **attrs)
      create_video(duration: duration, fingerprint: fp(*hashes), **attrs)
    end

    # ---- similarity ----------------------------------------------------

    def test_similar_uses_median_distance
      assert Dedupe.similar?([A, B, C], [A, B, C])
      assert Dedupe.similar?([A, B, C], [near(A, 10), near(B, 10), C])
      refute Dedupe.similar?([A, B, C], [near(A, 11), near(B, 11), C])
      assert Dedupe.similar?([A, B, C], [A, B, ~C & 0xffff_ffff_ffff_ffff]), 'one outlier frame is tolerated'
    end

    def test_similar_aligns_stills_by_relative_position_when_counts_differ
      long = [A, A, B, B, C, C]
      assert Dedupe.similar?([A, B, C], long)
      assert Dedupe.similar?(long, [A, B, C])
      refute Dedupe.similar?([C, B, A], long)
    end

    def test_similar_with_no_stills_is_false
      refute Dedupe.similar?([], [A])
      refute Dedupe.similar?([A], [])
    end

    def test_duration_tolerance
      assert_equal 0.75, Dedupe.duration_tolerance(10)
      assert_in_delta 2.0, Dedupe.duration_tolerance(1000)
    end

    # ---- grouping ------------------------------------------------------

    def test_groups_matching_videos_and_puts_suggested_keeper_first
      small = dupe(width: 640, height: 360, vcodec: 'h264', size: 10)
      big = dupe(duration: 60.5, width: 1920, height: 1080, vcodec: 'hevc', size: 5)
      same_px_h264 = dupe(duration: 60.2, width: 1920, height: 1080, vcodec: 'h264', size: 1)
      assert_equal [[same_px_h264.id, big.id, small.id]], Dedupe.groups.map { |g| g.map(&:id) }
    end

    def test_does_not_group_different_footage_or_different_lengths
      dupe
      dupe(hashes: [C, A, B])     # same length, different frames
      dupe(duration: 61.0)        # same frames, too different in length
      assert_empty Dedupe.groups
    end

    def test_excludes_non_ready_and_unfingerprinted_videos
      dupe
      dupe(status: 'ignored')
      dupe(status: 'pending')
      dupe(fingerprint: nil)
      create_video(duration: 60.0, fingerprint: '') # no stills
      assert_empty Dedupe.groups
    end

    def test_no_chaining_through_intermediate_matches
      # a~b and b~c, but a and c are too far apart: only a+b are grouped.
      a = dupe(hashes: [A])
      b = dupe(hashes: [near(A, 8)])
      c = dupe(hashes: [near(A, 16)])
      groups = Dedupe.groups.map { |g| g.map(&:id).sort }
      assert_equal [[a.id, b.id]], groups
      refute_includes groups.flatten, c.id
    end

    def test_dismissed_pairs_are_not_grouped
      a = dupe
      b = dupe
      Dedupe.dismiss!([a.id, b.id])
      assert_empty Dedupe.groups
    end

    def test_dismiss_records_every_pair_once
      Dedupe.dismiss!([3, 1, 2])
      Dedupe.dismiss!([2, 1])
      assert_equal [[1, 2], [1, 3], [2, 3]], DB[:dupe_dismissals].order(:a_id, :b_id).select_map(%i[a_id b_id])
    end

    def test_groups_sorted_longest_first
      dupe(duration: 10.0, hashes: [A])
      dupe(duration: 10.0, hashes: [A])
      dupe(duration: 90.0, hashes: [B])
      dupe(duration: 90.0, hashes: [B])
      assert_equal [90.0, 10.0], Dedupe.groups.map { |g| g.first.duration }
    end

    # ---- remove / restore ---------------------------------------------

    def test_remove_marks_ignored_and_purges_generated_assets_but_never_the_source
      v = dupe(hls_ready: true)
      src = add_media(v.rel_path)
      assets = make_assets(v.id)
      keep = dupe
      keep_assets = make_assets(keep.id)

      Dedupe.remove!([v.id])

      assert_equal ['ignored', false], [v.reload.status, v.hls_ready]
      assets.each { |p| refute File.exist?(p), "#{p} should be purged" }
      keep_assets.each { |p| assert File.exist?(p), "#{p} should be untouched" }
      assert File.file?(src), 'the original video file must never be touched'
    end

    def test_restore_requeues_an_ignored_video
      v = dupe(status: 'ignored', error: 'x')
      Dedupe.restore!(v)
      assert_equal ['pending', nil, nil], [v.reload.status, v.fingerprint, v.error]
      assert_equal [v.id], queued_ids
    end

    def test_restore_is_a_noop_for_videos_that_are_not_ignored
      v = dupe
      Dedupe.restore!(v)
      assert_equal 'ready', v.reload.status
      assert_empty queued_ids
    end

    # ---- backfill ------------------------------------------------------

    def test_backfill_marks_videos_without_stills_as_done
      v = create_video(fingerprint: nil)
      assert Dedupe.backfill!
      assert_equal '', v.reload.fingerprint
      assert_equal 0, Dedupe.unfingerprinted.count
    end

    def test_backfill_continues_past_failures
      a = create_video(fingerprint: nil)
      b = create_video(fingerprint: nil)
      fake = ->(id) { id == a.id ? raise('ffmpeg exploded') : 'abc' }
      _, err = capture_io { Dedupe.stub(:fingerprint, fake) { Dedupe.backfill! } }
      assert_match(/fingerprint failed for video #{a.id}/, err)
      assert_nil a.reload.fingerprint
      assert_equal 'abc', b.reload.fingerprint
      refute Dedupe.backfilling?
    end

    def test_backfill_refuses_to_run_concurrently
      Dedupe::LOCK.lock
      refute Dedupe.backfill!
    ensure
      Dedupe::LOCK.unlock
    end

    private

    def make_assets(id)
      FileUtils.mkdir_p([Ingest.stills_dir(id), Ingest.hls_path(id), "#{Ingest.hls_path(id)}.tmp"])
      paths = [Ingest.thumb_path(id), Ingest.preview_path(id), Ingest.still_path(id, 0),
               File.join(Ingest.hls_path(id), 'index.m3u8')]
      paths.each { |p| File.write(p, 'x') }
      paths + [Ingest.stills_dir(id), Ingest.hls_path(id), "#{Ingest.hls_path(id)}.tmp"]
    end
  end
end
