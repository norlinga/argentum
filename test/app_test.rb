require 'test_helper'

module Argentum
  class AppTest < TestCase
    include Rack::Test::Methods

    def app = App

    def htmx = { 'HTTP_HX_REQUEST' => 'true' }

    # ---- pages ---------------------------------------------------------

    def test_home_renders_sections
      create_video(title: 'Watched', duration: 100.0, position: 40.0, last_viewed_at: Time.now)
      get '/'
      assert last_response.ok?
      assert_includes last_response.body, 'Continue watching'
      assert_includes last_response.body, 'Recently added'
      assert_includes last_response.body, 'Watched'
    end

    def test_home_empty_library
      get '/'
      assert last_response.ok?
      assert_includes last_response.body, 'No videos yet'
    end

    def test_library_filters_and_hides_non_ready
      create_video(title: 'Beach day', tags: 'summer')
      create_video(title: 'Snow day')
      create_video(title: 'Beach pending', status: 'pending')
      get '/library', q: 'beach'
      assert last_response.ok?
      assert_includes last_response.body, 'Beach day'
      refute_includes last_response.body, 'Snow day'
      refute_includes last_response.body, 'Beach pending'
    end

    def test_library_paginates_htmx_fragments
      (App::PAGE_SIZE + 2).times { create_video }
      get '/library', { sort: 'title' }, htmx
      body = last_response.body
      refute_includes body, '<html', 'htmx requests get a fragment, not the layout'
      assert_equal App::PAGE_SIZE, body.scan('<article class="card"').size
      assert_includes body, 'hx-get="/library?sort=title&amp;page=2"'

      get '/library', { sort: 'title', page: 2 }, htmx
      assert_equal 2, last_response.body.scan('<article class="card"').size
      refute_includes last_response.body, 'sentinel'
    end

    def test_library_tolerates_junk_params
      create_video
      get '/library', page: '-5', sort: "'; drop table videos;--", fav: 'yes'
      assert last_response.ok?
      get '/library', 'q[]' => 'x', 'tag[a]' => 'b'
      assert last_response.ok?
    end

    def test_video_page
      v = create_video(title: 'Grandma')
      get "/videos/#{v.id}"
      assert last_response.ok?
      assert_includes last_response.body, '<title>Grandma · argentum</title>'
      assert_includes last_response.body, %(data-id="#{v.id}")
    end

    def test_unknown_video_is_404_everywhere
      %w[/videos/999 /videos/999/info /videos/999/edit /media/999 /videos/abc].each do |path|
        get path
        assert_equal 404, last_response.status, path
      end
      post '/videos/999/favorite'
      assert_equal 404, last_response.status
    end

    def test_user_content_is_html_escaped
      evil = '<script>alert(1)</script>'
      v = create_video(title: evil, description: evil, rel_path: "#{evil}.mp4", tags: '<b>x</b>')
      ["/videos/#{v.id}", '/library', "/videos/#{v.id}/edit", '/'].each do |path|
        get path
        refute_includes last_response.body, '<script>alert', path
        refute_includes last_response.body, '<b>x</b>', path
      end
    end

    def test_player_states
      { 'pending' => 'still being prepared', 'error' => "Couldn't process", 'missing' => "can't be found",
        'ignored' => 'removed from the library' }.each do |status, text|
        v = create_video(status: status, error: 'boom')
        get "/videos/#{v.id}/player"
        assert_includes last_response.body, text, status
      end
    end

    def test_ready_video_shows_last_reprocess_failure
      v = create_video(error: 'ffmpeg failed: disk full')
      get "/videos/#{v.id}"
      assert_includes last_response.body, 'Last reprocess failed: ffmpeg failed: disk full'
      assert_includes last_response.body, %(id="player")
      get "/videos/#{create_video.id}/info"
      refute_includes last_response.body, 'Last reprocess failed'
    end

    def test_processing_player_polls_and_ready_player_does_not
      get "/videos/#{create_video(status: 'processing').id}/player"
      assert_includes last_response.body, 'hx-trigger="every 5s"'
      get "/videos/#{create_video.id}/player"
      refute_includes last_response.body, 'hx-trigger'
    end

    # ---- editing -------------------------------------------------------

    def test_update_title_description_and_tags
      v = create_video(title: 'Old', tags: 'x')
      put "/videos/#{v.id}", title: '  New title ', description: ' about ', tags: 'Family, 2019'
      assert last_response.ok?
      v.reload
      assert_equal ['New title', 'about', %w[2019 family]], [v.title, v.description, v.tag_names]
      assert_includes last_response.body, 'New title'
    end

    def test_blank_title_keeps_existing_one
      v = create_video(title: 'Keep me')
      put "/videos/#{v.id}", title: '   '
      assert_equal 'Keep me', v.reload.title
    end

    def test_update_chooses_existing_still_as_thumbnail
      v = create_video(thumb_index: 0)
      FileUtils.mkdir_p(Ingest.stills_dir(v.id))
      2.times { |i| File.write(Ingest.still_path(v.id, i), "still#{i}") }
      put "/videos/#{v.id}", title: 'x', thumb: '1'
      assert_equal 1, v.reload.thumb_index
      assert_equal 'still1', File.read(Ingest.thumb_path(v.id))
    end

    def test_update_ignores_bogus_thumb_values
      v = create_video(thumb_index: 0)
      ['9', '-1', '../1', '1abc'].each do |thumb|
        put "/videos/#{v.id}", title: 'x', thumb: thumb
        assert last_response.ok?, thumb
        assert_equal 0, v.reload.thumb_index, thumb
      end
    end

    def test_toggle_favorite
      v = create_video
      post "/videos/#{v.id}/favorite"
      assert v.reload.favorite
      assert_includes last_response.body, 'aria-pressed="true"'
      post "/videos/#{v.id}/favorite"
      refute v.reload.favorite
    end

    # ---- playback tracking --------------------------------------------

    def test_view_increments_count
      v = create_video
      2.times { post "/videos/#{v.id}/view" }
      assert_equal 204, last_response.status
      v.reload
      assert_equal 2, v.view_count
      refute_nil v.last_viewed_at
    end

    def test_progress_is_saved_and_clamped
      v = create_video(duration: 100.0)
      post "/videos/#{v.id}/progress", position: '42.5'
      assert_equal 204, last_response.status
      assert_equal 42.5, v.reload.position
      post "/videos/#{v.id}/progress", position: '-3'
      assert_equal 0.0, v.reload.position
      post "/videos/#{v.id}/progress", position: 'garbage'
      assert_equal 0.0, v.reload.position
      post "/videos/#{v.id}/progress", position: '1e999'
      assert_equal 204, last_response.status
      assert_equal 0.0, v.reload.position
      post "/videos/#{v.id}/progress", position: '500'
      assert_equal 100.0, v.reload.position
    end

    # Two plays at once both load view_count N; a Ruby-side `N + 1` would lose one.
    # Handing the route a stale row makes that race deterministic.
    def test_view_increment_is_relative_to_the_database_not_the_loaded_row
      v = create_video(view_count: 5)
      stale = Video[v.id].tap { |row| row.values[:view_count] = 0 }
      Video.stub(:[], stale) { post "/videos/#{v.id}/view" }
      assert_equal 204, last_response.status
      assert_equal 6, v.reload.view_count
    end

    def test_partial_video_ids_cannot_edit_an_existing_video
      v = create_video
      post "/videos/#{v.id}abc/favorite"
      assert_equal 404, last_response.status
      refute v.reload.favorite
    end

    def test_media_symlink_replaced_after_scan_cannot_serve_outside_media
      path = add_media('clip.mp4')
      Scanner.scan!
      v = Video.first
      outside = File.join(TEST_ROOT, 'private.txt')
      File.write(outside, 'private contents')
      File.delete(path)
      File.symlink(outside, path)
      get "/media/#{v.id}"
      assert_equal 404, last_response.status
      refute_includes last_response.body, 'private contents'
    end

    # ---- processing controls -----------------------------------------

    def test_reprocess_error_video_resets_and_queues
      v = create_video(status: 'error', error: 'boom')
      post "/videos/#{v.id}/reprocess"
      assert last_response.redirect?
      assert_equal ['pending', nil], [v.reload.status, v.error]
      assert_equal [v.id], queued_ids
    end

    def test_reprocess_ready_video_via_htmx_keeps_player
      v = create_video
      post "/videos/#{v.id}/reprocess", {}, htmx
      assert_equal 'ready', v.reload.status
      assert_includes last_response.body, 'Reprocessing queued'
      refute_includes last_response.body, 'hx-swap-oob'
    end

    def test_reprocess_pending_video_via_htmx_swaps_in_poller
      v = create_video(status: 'error')
      post "/videos/#{v.id}/reprocess", {}, htmx
      assert_includes last_response.body, 'id="stage" hx-swap-oob="true"'
    end

    def test_reprocess_all_and_status
      create_video
      create_video(status: 'ignored')
      post '/reprocess'
      assert_includes last_response.body, 'Preparing 1 video…'
      get '/status'
      assert_includes last_response.body, 'Preparing 1 video…'
    end

    def test_scan_runs_in_background
      add_media('new.mp4')
      post '/scan'
      assert_includes last_response.body, 'Scanning…'
      deadline = Time.now + 2
      sleep 0.01 until Video.count.positive? || Time.now > deadline
      assert_equal ['new.mp4'], Video.select_map(:rel_path)
    end

    # ---- duplicates ---------------------------------------------------

    def test_duplicates_page_lists_groups_and_removed
      fp = '0f0f0f0f0f0f0f0f'
      create_video(title: 'Copy A', duration: 10.0, fingerprint: fp)
      create_video(title: 'Copy B', duration: 10.0, fingerprint: fp)
      create_video(rel_path: 'gone/hidden.mp4', status: 'ignored', fingerprint: '')
      get '/duplicates'
      assert last_response.ok?
      body = last_response.body
      assert_includes body, '1 possible duplicate group'
      assert_includes body, 'Copy A'
      assert_includes body, 'Copy B'
      assert_includes body, 'gone/hidden.mp4'
      assert_equal 1, body.scan(/name="remove\[\]" value="\d+" checked/).size, 'all but the keeper pre-ticked'
    end

    def test_remove_duplicates_only_removes_ids_in_the_group
      a = create_video
      b = create_video
      outsider = create_video
      post '/duplicates/remove', ids: [a.id, b.id], remove: [b.id, outsider.id]
      assert last_response.ok?
      assert_equal %w[ready ignored ready], [a, b, outsider].map { |v| v.reload.status }
      assert_includes last_response.body, 'Removed 1 copy.'
      assert_includes last_response.body, %(Kept #{File.basename(a.rel_path)})
      assert_includes last_response.body, 'id="ignored" hx-swap-oob="true"'
    end

    def test_dismiss_duplicates
      a = create_video
      b = create_video
      post '/duplicates/dismiss', ids: [a.id, b.id, a.id]
      assert last_response.ok?
      assert_equal [[a.id, b.id].minmax], DB[:dupe_dismissals].select_map(%i[a_id b_id])
    end

    def test_restore
      v = create_video(status: 'ignored')
      post "/videos/#{v.id}/restore", {}, htmx
      assert last_response.ok?
      assert_equal 'pending', v.reload.status
    end

    # ---- media serving ------------------------------------------------

    def test_serves_original_with_byte_ranges
      v = create_video(rel_path: 'sub/clip.mov')
      add_media('sub/clip.mov', content: '0123456789')
      get "/media/#{v.id}", {}, 'HTTP_RANGE' => 'bytes=2-5'
      assert_equal 206, last_response.status
      assert_equal '2345', last_response.body
      assert_equal 'video/quicktime', last_response.content_type
    end

    def test_missing_original_is_404
      v = create_video
      get "/media/#{v.id}"
      assert_equal 404, last_response.status
    end

    def test_serves_generated_assets
      v = create_video
      FileUtils.mkdir_p([Ingest.hls_path(v.id), Ingest.stills_dir(v.id)])
      File.write(Ingest.thumb_path(v.id), 'thumb')
      File.write(Ingest.still_path(v.id, 3), 'still')
      File.write(Ingest.preview_path(v.id), 'preview')
      File.write(File.join(Ingest.hls_path(v.id), 'index.m3u8'), '#EXTM3U')
      File.write(File.join(Ingest.hls_path(v.id), 'seg00000.ts'), 'ts')

      { "/thumbs/#{v.id}.jpg" => ['thumb', 'image/jpeg'],
        "/stills/#{v.id}/3.jpg" => ['still', 'image/jpeg'],
        "/previews/#{v.id}.mp4" => ['preview', 'video/mp4'],
        "/hls/#{v.id}/index.m3u8" => ['#EXTM3U', 'application/vnd.apple.mpegurl'],
        "/hls/#{v.id}/seg00000.ts" => ['ts', 'video/mp2t'] }.each do |path, (body, type)|
        get path
        assert last_response.ok?, path
        assert_equal [body, type], [last_response.body, last_response.media_type], path
      end
    end

    def test_hls_route_cannot_escape_the_video_dir
      v = create_video
      File.write(File.join(Config.data_dir, 'secret.txt'), 'secret')
      FileUtils.mkdir_p(Ingest.hls_path(v.id))
      ["/hls/#{v.id}/..", "/hls/#{v.id}/..%2F..%2Fsecret.txt", "/hls/#{v.id}/%2e%2e%2f%2e%2e%2fsecret.txt",
       "/hls/#{v.id}/../../secret.txt", "/hls/../secret.txt"].each do |path|
        get path
        refute_includes last_response.body, 'secret', path
        refute last_response.ok?, path
      end
    end

    def test_thumb_url_cache_busts_on_change
      v = create_video
      get "/videos/#{v.id}/info"
      assert_includes last_response.body, "/thumbs/#{v.id}.jpg?t=0"
      File.write(Ingest.thumb_path(v.id), 'x')
      get "/videos/#{v.id}/info"
      assert_match(%r{/thumbs/#{v.id}\.jpg\?t=[1-9]\d+}, last_response.body)
    end
  end

  class AppHelpersTest < Minitest::Test
    def helpers = App.new! # bare instance (no middleware) exposes the helper methods

    def test_human_size
      h = helpers
      assert_equal '—', h.human_size(nil)
      assert_equal '0 B', h.human_size(0)
      assert_equal '512 B', h.human_size(512)
      assert_equal '1.0 KB', h.human_size(1024)
      assert_equal '1.5 MB', h.human_size(1024 * 1024 * 3 / 2)
      assert_equal '2.0 TB', h.human_size(2 * 1024**4)
      assert_equal '2048.0 TB', h.human_size(2 * 1024**5), 'caps at TB'
    end
  end
end
