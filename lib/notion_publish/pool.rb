# frozen_string_literal: true

module NotionPublish
  # Runs work over a list a few items at a time, and hands the results back
  # in the list's order.
  #
  # Checking a page is almost all waiting on Notion, so a few requests in
  # flight cut the time roughly by that factor. Notion allows about three
  # requests a second on average; more workers than that would mostly buy
  # rate-limit retries.
  #
  # Only the work runs on worker threads. The +started+ and +finished+
  # callbacks and the block run on the calling thread, so everything that
  # prints does so from one thread, in order.
  class Pool
    SIZE = 3

    # Calls +work+ with each item on a worker thread. On the calling thread,
    # calls +started+ with an item when a worker picks it up, +finished+ with
    # the number of items done so far, and yields each item with its result
    # in the original order as soon as every item before it is done. Returns
    # the results in order.
    #
    # An exception raised by +work+ stops the run and is raised here, once
    # the items before it have been yielded.
    def self.run(items, work:, size: SIZE, started: nil, finished: nil, &emit)
      new(items, work: work, started: started, finished: finished, emit: emit).run(size)
    end

    def initialize(items, work:, started:, finished:, emit:)
      @items = items
      @work = work
      @started = started
      @finished = finished
      @emit = emit
      @results = Array.new(items.length)
      @events = Queue.new
    end

    def run(size)
      return [] if @items.empty?

      workers = Array.new([size, @items.length].min) { worker(jobs) }
      collect
      @results.map { |_, value| value }
    ensure
      workers&.each(&:kill)
    end

    private

    def jobs
      @jobs ||= Queue.new.tap do |queue|
        @items.each_with_index { |item, index| queue << [item, index] }
        queue.close
      end
    end

    def worker(queue)
      Thread.new do
        while (job = queue.pop)
          item, index = job
          @events << [:started, index]
          @results[index] = attempt(item)
          @events << [:finished, index]
        end
      end
    end

    def attempt(item)
      [:ok, @work.call(item)]
    rescue StandardError => e
      [:raised, e]
    end

    # Until every item has reported finishing, not merely until every result
    # is in: a worker stores its result just before it says so.
    def collect
      done = 0
      emitted = 0
      while done < @items.length
        kind, index = @events.pop
        next @started&.call(@items[index]) if kind == :started

        done += 1
        @finished&.call(done)
        emitted = emit_ready(emitted)
      end
    end

    # Yields every finished result that has no unfinished item before it.
    def emit_ready(emitted)
      while emitted < @items.length && @results[emitted]
        status, value = @results[emitted]
        raise value if status == :raised

        @emit&.call(@items[emitted], value)
        emitted += 1
      end
      emitted
    end
  end
end
