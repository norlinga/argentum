require 'test_helper'

module Argentum
  class BootTest < TestCase
    def setup
      super
      @threads_before = Thread.list
    end

    def teardown
      (Thread.list - @threads_before).each(&:kill).each(&:join)
      super
    end

    # A failed scan (e.g. the media mount briefly gone) must not stop later rescans,
    # nor skip the fingerprint backfill that follows the initial scan.
    def test_scan_failures_do_not_stop_rescans_or_backfill
      unfingerprinted = create_video(fingerprint: nil)
      calls = 0
      failing_scan = lambda do
        calls += 1
        raise Errno::ENOENT, Config.media_dir
      end

      _, err = capture_io do
        with_env('ARGENTUM_SCAN_INTERVAL' => '1') do
          Scanner.stub(:scan!, failing_scan) do
            Argentum.boot!
            deadline = Time.now + 5
            sleep 0.05 until (calls >= 3 && !unfingerprinted.reload.fingerprint.nil?) || Time.now > deadline
          end
        end
      end

      assert_operator calls, :>=, 3, 'initial scan plus at least two periodic rescans'
      assert_equal '', unfingerprinted.reload.fingerprint, 'backfill still ran after the initial scan failed'
      assert_match(/initial scan failed: Errno::ENOENT/, err)
      assert_match(/argentum: scan failed: Errno::ENOENT/, err)
    end

    def test_invalid_configuration_fails_at_boot_before_starting_threads
      with_env('ARGENTUM_FFMPEG_THREADS' => '0') do
        assert_raises(ArgumentError) { Argentum.boot! }
      end
      assert_empty Thread.list - @threads_before
    end
  end
end
