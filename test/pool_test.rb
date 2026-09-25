# frozen_string_literal: true

require "test_helper"

class PoolTest < Minitest::Test
  # Later items finish first; results still come back in the list's order.
  def test_results_are_emitted_in_order_whatever_order_they_finish_in
    emitted = []
    results = NotionPublish::Pool.run([3, 2, 1], work: lambda { |n|
      sleep(n * 0.02)
      n * 10
    }) { |item, value| emitted << [item, value] }

    assert_equal [[3, 30], [2, 20], [1, 10]], emitted
    assert_equal [30, 20, 10], results
  end

  def test_work_runs_concurrently
    in_flight = 0
    peak = 0
    lock = Mutex.new
    NotionPublish::Pool.run((1..6).to_a, size: 3, work: lambda { |_|
      lock.synchronize { peak = [peak, in_flight += 1].max }
      sleep 0.03
      lock.synchronize { in_flight -= 1 }
    })

    assert_equal 3, peak
  end

  def test_finished_counts_up_to_the_total
    counts = []
    NotionPublish::Pool.run(%w[a b c], work: ->(x) { x }, finished: ->(done) { counts << done })

    assert_equal [1, 2, 3], counts
  end

  def test_callbacks_run_on_the_calling_thread
    threads = []
    NotionPublish::Pool.run(%w[a b], work: ->(x) { x },
                                     started: ->(_) { threads << Thread.current },
                                     finished: ->(_) { threads << Thread.current }) { |_, _| threads << Thread.current }

    assert_equal [Thread.current], threads.uniq
  end

  def test_an_error_in_the_work_is_raised_after_earlier_results_are_emitted
    emitted = []
    error = assert_raises(RuntimeError) do
      NotionPublish::Pool.run([1, 2, 3], work: lambda { |n|
        raise "boom on #{n}" if n == 2

        n
      }) { |item, _| emitted << item }
    end

    assert_equal "boom on 2", error.message
    assert_equal [1], emitted
  end

  def test_an_empty_list_does_nothing
    assert_equal [], NotionPublish::Pool.run([], work: ->(_) { flunk })
  end
end
