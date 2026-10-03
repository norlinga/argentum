require 'test_helper'

module Argentum
  class WorkerTest < TestCase
    def test_enqueue_is_idempotent_while_queued
      Worker.enqueue(1)
      Worker.enqueue(1)
      Worker.enqueue(2)
      assert_equal 2, Worker::QUEUE.size
      assert_equal 2, Worker.outstanding
    end

    def test_enqueue_pending_only_queues_pending
      p = create_video(status: 'pending')
      %w[ready error missing ignored processing].each { |s| create_video(status: s) }
      Worker.enqueue_pending
      assert_equal [p.id], queued_ids
    end

    def test_reprocess_all_requeues_active_videos_and_resets_errors
      ready = create_video(status: 'ready')
      err = create_video(status: 'error', error: 'boom')
      missing = create_video(status: 'missing')
      ignored = create_video(status: 'ignored')
      Worker.reprocess_all

      assert_equal [ready.id, err.id].sort, queued_ids.sort
      assert_equal ['pending', nil], [err.reload.status, err.error]
      assert_equal 'ready', ready.reload.status, 'ready videos stay playable while regenerated'
      assert_equal %w[missing ignored], [missing.reload.status, ignored.reload.status]
    end

    def test_start_resets_videos_interrupted_mid_processing
      v = create_video(status: 'processing')
      with_worker { assert_equal 'pending', v.reload.status }
    end

    def test_processes_queue_and_clears_outstanding
      seen = []
      v = create_video(status: 'pending')
      skipped = create_video(status: 'ignored')
      Ingest.stub(:process, ->(video) { seen << video.id }) do
        with_worker do
          Worker.enqueue(skipped.id)
          Worker.enqueue(v.id)
          Worker.enqueue(999_999) # deleted row
          wait_until { Worker.outstanding.zero? }
        end
      end
      assert_equal [v.id], seen
    end

    # e.g. SQLite BUSY raised from inside Ingest.process's own rescue.
    def test_worker_survives_an_unexpected_exception
      a = create_video(status: 'pending')
      b = create_video(status: 'pending')
      seen = []
      fake = lambda do |video|
        seen << video.id
        raise Sequel::DatabaseError, 'database is locked' if video.id == a.id
      end
      _, err = capture_io do
        Ingest.stub(:process, fake) do
          with_worker do
            Worker.enqueue(a.id)
            Worker.enqueue(b.id)
            wait_until { Worker.outstanding.zero? }
          end
        end
      end
      assert_equal [a.id, b.id], seen
      assert_match(/ingest failed for video #{a.id}: Sequel::DatabaseError: database is locked/, err)
    end

    private

    def with_worker
      thread = Worker.start
      thread.report_on_exception = false
      yield
    ensure
      thread&.kill
      begin
        thread&.join
      rescue StandardError
        nil # a crashed worker re-raises on join; the test's own assertions report it
      end
    end

    def wait_until(timeout: 2)
      deadline = Time.now + timeout
      sleep 0.01 until yield || Time.now > deadline
      assert yield, 'timed out waiting for worker'
    end
  end
end
