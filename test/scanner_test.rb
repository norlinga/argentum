require 'test_helper'

module Argentum
  class ScannerTest < TestCase
    def test_registers_new_videos_as_pending_with_title_and_folder_tags
      add_media('Family_Trips/summer-2019/beach_day-01.MP4', content: 'abc')
      assert Scanner.scan!

      v = Video.first
      assert_equal 'Family_Trips/summer-2019/beach_day-01.MP4', v.rel_path
      assert_equal 'Beach day 01', v.title
      assert_equal 'pending', v.status
      assert_equal 3, v.size
      assert_equal ['family trips', 'summer 2019'], v.tag_names
      assert_equal [v.id], queued_ids
    end

    def test_files_at_root_get_no_tags
      add_media('clip.mp4')
      Scanner.scan!
      assert_empty Video.first.tag_names
    end

    def test_ignores_non_video_files_and_hidden_paths
      add_media('notes.txt')
      add_media('.hidden.mp4')
      add_media('.thumbnails/x.mp4')
      add_media('sub/.cache/y.mov')
      add_media('ok.MKV')
      Scanner.scan!
      assert_equal ['ok.MKV'], Video.select_map(:rel_path)
    end

    def test_rescan_of_unchanged_file_is_a_noop
      add_media('a.mp4')
      Scanner.scan!
      Video.first.update(status: 'ready')
      Scanner.scan!
      assert_equal 'ready', Video.first.status
      assert_equal 1, Video.count
    end

    def test_changed_file_is_requeued
      path = add_media('a.mp4', content: 'one')
      Scanner.scan!
      v = Video.first
      v.update(status: 'ready')
      Worker::QUEUED.clear
      File.write(path, 'longer content')
      Scanner.scan!
      assert_equal 'pending', v.reload.status
      assert_equal 14, v.size
      assert_equal [v.id], queued_ids
    end

    def test_vanished_file_is_marked_missing_and_metadata_kept
      path = add_media('a.mp4')
      Scanner.scan!
      v = Video.first
      v.update(status: 'ready', title: 'Edited', favorite: true, view_count: 3)
      v.set_tags('kept')
      File.delete(path)
      Scanner.scan!
      v.reload
      assert_equal 'missing', v.status
      assert_equal ['Edited', true, 3, ['kept']], [v.title, v.favorite, v.view_count, v.tag_names]
    end

    def test_returning_file_is_ready_again_if_it_had_been_ingested
      path = add_media('a.mp4')
      Scanner.scan!
      v = Video.first
      v.update(status: 'ready')
      File.write(Ingest.thumb_path(v.id), 'jpg')
      File.rename(path, "#{path}.bak")
      Scanner.scan!
      assert_equal 'missing', v.reload.status
      File.rename("#{path}.bak", path)
      Scanner.scan!
      assert_equal 'ready', v.reload.status
    end

    def test_returning_file_without_assets_goes_back_to_pending
      path = add_media('a.mp4')
      Scanner.scan!
      v = Video.first
      File.rename(path, "#{path}.bak")
      Scanner.scan!
      File.rename("#{path}.bak", path)
      Scanner.scan!
      assert_equal 'pending', v.reload.status
    end

    def test_ignored_videos_are_never_reregistered_or_reset
      path = add_media('dupe.mp4', content: 'a')
      Scanner.scan!
      v = Video.first
      v.update(status: 'ignored')
      Worker::QUEUED.clear
      File.write(path, 'changed content') # even a modified file stays ignored
      Scanner.scan!
      assert_equal 'ignored', v.reload.status
      assert_empty queued_ids

      File.delete(path) # and is not flipped to missing either
      Scanner.scan!
      assert_equal 'ignored', v.reload.status
    end

    def test_concurrent_scan_is_refused
      Scanner::LOCK.lock
      refute Scanner.scan!
    ensure
      Scanner::LOCK.unlock
    end

    def test_symlinks_outside_media_are_skipped_but_internal_links_are_supported
      outside = File.join(TEST_ROOT, 'private.mp4')
      File.write(outside, 'private')
      File.symlink(outside, File.join(Config.media_dir, 'outside.mp4'))
      add_media('inside.mp4')
      File.symlink(File.join(Config.media_dir, 'inside.mp4'), File.join(Config.media_dir, 'alias.mp4'))
      Scanner.scan!
      assert_equal %w[alias.mp4 inside.mp4], Video.order(:rel_path).select_map(:rel_path)
    end

    def test_lock_is_released_after_an_error
      FileUtils.rm_rf(Config.media_dir)
      assert_raises(Errno::ENOENT) { Scanner.scan! }
      refute Scanner::LOCK.locked?
    end

    # A missing/unmounted media dir must not mark the whole library missing.
    def test_missing_media_dir_does_not_mark_library_missing
      create_video(rel_path: 'a.mp4')
      FileUtils.rm_rf(Config.media_dir)
      assert_raises(Errno::ENOENT) { Scanner.scan! }
      assert_equal ['ready'], Video.select_map(:status)
    end

    # ---- files still arriving (e.g. LocalSend into the media folder) ----

    def test_file_still_being_written_is_left_alone_until_it_settles
      path = add_media('arriving.mp4')
      with_env('ARGENTUM_SETTLE_SECONDS' => '30') do
        Scanner.stub(:schedule_rescan, nil) { Scanner.scan! }
        assert_equal 0, Video.count

        File.utime(Time.now - 31, Time.now - 31, path) # quiet for long enough now
        Scanner.scan!
      end
      assert_equal ['pending'], Video.select_map(:status)
    end

    def test_unsettled_file_schedules_a_prompt_rescan
      add_media('arriving.mp4')
      delays = []
      with_env('ARGENTUM_SETTLE_SECONDS' => '30') do
        Scanner.stub(:schedule_rescan, ->(*args) { delays << args }) { Scanner.scan! }
      end
      assert_equal 1, delays.size
    end

    def test_settled_library_schedules_no_rescan
      add_media('old.mp4')
      called = false
      Scanner.stub(:schedule_rescan, -> { called = true }) { Scanner.scan! }
      refute called
    end

    def test_existing_video_being_rewritten_is_not_marked_missing
      path = add_media('a.mp4', content: 'one')
      Scanner.scan!
      v = Video.first
      v.update(status: 'ready')
      File.write(path, 'one, and more arriving')
      with_env('ARGENTUM_SETTLE_SECONDS' => '30') do
        Scanner.stub(:schedule_rescan, nil) { Scanner.scan! }
      end
      assert_equal 'ready', v.reload.status
    end

    def test_scheduled_rescan_registers_the_file_once_settled
      path = add_media('arriving.mp4')
      with_env('ARGENTUM_SETTLE_SECONDS' => '1') do
        Scanner.scan!
        assert Scanner.rescan_scheduled?
        refute Scanner.schedule_rescan, 'only one rescan is pending at a time'
        deadline = Time.now + 5
        sleep 0.05 until Video.count.positive? || Time.now > deadline
      end
      assert_equal ['arriving.mp4'], Video.select_map(:rel_path)
      assert File.file?(path)
    end

    def test_titleize
      assert_equal 'My video', Scanner.titleize('dir/my__video.mp4')
      assert_equal 'Clip 2', Scanner.titleize('clip.-2.mov')
      assert_equal '---.mp4', Scanner.titleize('---.mp4'), 'falls back to the path when nothing is left'
    end
  end
end
