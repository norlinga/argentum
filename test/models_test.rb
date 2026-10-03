require 'test_helper'

module Argentum
  class TagTest < TestCase
    def test_normalize_lowercases_trims_collapses_whitespace_and_dedupes
      assert_equal ['summer trip', 'beach'], Tag.normalize(' Summer   Trip, BEACH ,, beach,  ')
    end

    def test_normalize_handles_nil_and_empty
      assert_equal [], Tag.normalize(nil)
      assert_equal [], Tag.normalize(' , ,')
    end

    def test_hue_is_stable_and_in_range
      assert_equal Tag.hue('beach'), Tag.hue('beach')
      %w[a beach Ünïcödé 🎂birthday].each { |n| assert_includes 0..359, Tag.hue(n) }
    end

    # argentum.js recomputes hues client-side for the live tag preview; the two must agree.
    def test_hue_matches_javascript_implementation
      skip 'node not installed' unless system('node --version > /dev/null 2>&1')

      names = ['beach', 'summer trip', 'Ünïcödé', '🎂 birthday', 'a' * 200]
      js = File.read(File.expand_path('../public/js/argentum.js', __dir__))[/const tagHue = .*?\n};/m]
      script = "#{js}\nconsole.log(JSON.stringify(#{names.to_json}.map(tagHue)));"
      out = IO.popen(['node', '-e', script], &:read)
      assert_equal names.map { |n| Tag.hue(n) }, JSON.parse(out)
    end

    def test_counts_only_ready_videos_most_used_first
      create_video(tags: 'beach, dogs')
      create_video(tags: 'beach')
      create_video(tags: 'beach, cats', status: 'pending')
      create_video(tags: 'cats', status: 'ignored')

      assert_equal [{ name: 'beach', n: 2 }, { name: 'dogs', n: 1 }], Tag.counts
    end
  end

  class VideoTaggingTest < TestCase
    def test_set_tags_replaces_existing_tags
      v = create_video(tags: 'a, b')
      v.set_tags('b, c')
      assert_equal %w[b c], v.reload.tag_names
    end

    def test_set_tags_accepts_array
      v = create_video
      v.set_tags(['Dogs', 'cats, birds'])
      assert_equal %w[birds cats dogs], v.tag_names
    end

    def test_set_tags_deletes_orphaned_tags_but_keeps_shared_ones
      a = create_video(tags: 'shared, only-a')
      create_video(tags: 'shared')
      a.set_tags('')
      assert_equal ['shared'], Tag.select_map(:name)
    end

    def test_set_tags_clears_cached_association
      v = create_video(tags: 'old')
      assert_equal ['old'], v.tag_names # loads and caches the association
      v.set_tags('new')
      assert_equal ['new'], v.tag_names
    end

    def test_deleting_a_video_cascades_taggings
      v = create_video(tags: 'x')
      v.destroy
      assert_equal 0, DB[:taggings].count
    end
  end

  class VideoSearchTest < TestCase
    def search(**opts) = Video.ready.search(**opts).select_map(:title)

    def test_query_matches_title_description_path_and_tag_case_insensitively
      create_video(title: 'Beach day')
      create_video(title: 'One', description: 'at the BEACH')
      create_video(title: 'Two', rel_path: 'beach/two.mp4')
      create_video(title: 'Three', tags: 'beachy')
      create_video(title: 'Unrelated')
      assert_equal ['Beach day', 'One', 'Three', 'Two'], search(q: 'beach').sort
    end

    def test_query_tokens_are_anded
      create_video(title: 'Beach birthday')
      create_video(title: 'Beach day')
      create_video(title: 'Birthday', tags: 'beach')
      assert_equal ['Beach birthday', 'Birthday'], search(q: 'beach  birthday').sort
    end

    def test_like_wildcards_in_query_are_literal
      create_video(title: '100% fun')
      create_video(title: '100 fun')
      create_video(title: 'a_b')
      create_video(title: 'axb')
      assert_equal ['100% fun'], search(q: '100%')
      assert_equal ['a_b'], search(q: 'a_b')
    end

    def test_tag_filter_is_exact
      create_video(title: 'A', tags: 'dog')
      create_video(title: 'B', tags: 'dogs')
      assert_equal ['A'], search(tag: 'dog')
    end

    def test_favorite_filter
      create_video(title: 'Fav', favorite: true)
      create_video(title: 'Meh')
      assert_equal ['Fav'], search(fav: true)
    end

    def test_only_ready_videos_when_scoped
      create_video(title: 'Ready')
      %w[pending processing error missing ignored].each { |s| create_video(title: s, status: s) }
      assert_equal ['Ready'], search
    end

    def test_sorts
      create_video(title: 'b', mtime: 1, view_count: 5)
      create_video(title: 'C', mtime: 3, view_count: 0)
      create_video(title: 'a', mtime: 2, view_count: 9)
      assert_equal %w[C a b], search(sort: 'newest')
      assert_equal %w[a b C], search(sort: 'popular')
      assert_equal %w[C b a], search(sort: 'least')
      assert_equal %w[a b C], search(sort: 'title')
      assert_equal %w[C a b], search(sort: 'random').sort
      assert_equal %w[C a b], search(sort: 'bogus'), 'unknown sort falls back to newest'
    end
  end

  class VideoPlaybackTest < TestCase
    def test_duration_label
      assert_nil Video.new(duration: nil).duration_label
      assert_equal '0:07', Video.new(duration: 7.9).duration_label
      assert_equal '12:05', Video.new(duration: 725).duration_label
      assert_equal '1:02:03', Video.new(duration: 3723).duration_label
    end

    def test_resumable_only_between_five_seconds_in_and_ten_seconds_from_end
      v = Video.new(duration: 100.0)
      { 0.0 => false, 5.0 => false, 5.1 => true, 89.9 => true, 90.0 => false, 150.0 => false }.each do |pos, want|
        v.position = pos
        assert_equal want, !!v.resumable?, "position #{pos}"
      end
      refute Video.new(duration: nil, position: 50.0).resumable?
    end

    def test_progress_pct
      assert_equal 25, Video.new(duration: 100.0, position: 25.0).progress_pct
      assert_equal 0, Video.new(duration: 100.0, position: 95.0).progress_pct
    end

    def test_continue_watching_orders_by_last_viewed_and_skips_finished
      old = create_video(duration: 100.0, position: 30.0, last_viewed_at: Time.now - 60)
      recent = create_video(duration: 100.0, position: 30.0, last_viewed_at: Time.now)
      create_video(duration: 100.0, position: 95.0, last_viewed_at: Time.now) # nearly finished
      create_video(duration: 100.0, position: 0.0, last_viewed_at: Time.now)  # never started
      create_video(duration: 100.0, position: 30.0, status: 'missing')
      assert_equal [recent.id, old.id], Video.continue_watching.map(&:id)
    end
  end

  class VideoDiscoveryTest < TestCase
    def test_title_tokens_drop_short_words_and_stopwords
      assert_equal %w[grandma birthday party], Video.new(title: 'IMG 0042 Grandma the Birthday-party.MOV').title_tokens
    end

    def test_related_ranks_shared_tags_over_title_words
      me = create_video(title: 'Grandma birthday', tags: 'family, 2019')
      by_tag = create_video(title: 'Something', tags: 'family')
      by_word = create_video(title: 'Birthday cake')
      both = create_video(title: 'Grandma visit', tags: 'family, 2019')
      create_video(title: 'Unrelated', tags: 'work')
      create_video(title: 'Grandma birthday copy', tags: 'family', status: 'pending')

      assert_equal [both.id, by_tag.id, by_word.id], me.related.map(&:id)
    end

    def test_related_never_includes_self
      me = create_video(title: 'Grandma birthday', tags: 'family')
      assert_empty me.related
    end

    def test_related_scores_across_batches_and_uses_whole_title_words
      me = create_video(title: 'Birthday', tags: 'family')
      130.times { create_video(title: 'Birthday cake', view_count: 1) }
      create_video(title: 'Birthdays') # substring candidate, but no shared token
      winner = create_video(title: 'Birthday party', tags: 'family', view_count: 5)
      result = me.related(limit: 3)
      assert_equal 3, result.size
      assert_equal winner.id, result.first.id
      assert result.all? { |v| v.title_tokens.include?('birthday') }
    end

    def test_home_mix_returns_unique_ready_videos_up_to_total
      30.times { |i| create_video(view_count: i) }
      create_video(status: 'pending')
      mix = Video.home_mix
      assert_equal 16, mix.size
      assert_equal mix.size, mix.map(&:id).uniq.size
      assert(mix.all?(&:ready?))
    end

    def test_home_mix_with_small_library_includes_everything_once
      vids = Array.new(3) { create_video }
      assert_equal vids.map(&:id).sort, Video.home_mix.map(&:id).sort
    end

    def test_home_mix_empty_library
      assert_empty Video.home_mix
    end
  end
end
