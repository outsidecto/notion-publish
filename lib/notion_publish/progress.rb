# frozen_string_literal: true

require "delegate"
require "io/console"

module NotionPublish
  # A single progress line on a terminal, such as "Checking 12/38  a.md":
  # how many items are finished, and one that is in progress. It is rewritten
  # in place and cleared when the run ends.
  #
  # It exists only when stderr is a terminal, following git, curl, and rsync,
  # so CI logs and pipes never see it. Output written through #wrap clears the
  # line first and redraws it afterwards, so results and the progress line
  # never share a line. A disabled Progress does nothing and wraps nothing.
  class Progress
    CLEAR = "\r\e[K"
    DEFAULT_WIDTH = 80

    # An IO that keeps the progress line out of the way of what it writes.
    class Output < SimpleDelegator
      def initialize(io, progress)
        super(io)
        @progress = progress
      end

      def puts(*) = @progress.around { __getobj__.puts(*) }
      def print(*) = @progress.around { __getobj__.print(*) }
      def write(*) = @progress.around { __getobj__.write(*) }
    end

    def initialize(io, enabled:)
      @io = io
      @enabled = enabled
      @line = nil
    end

    def enabled? = @enabled

    def wrap(io) = enabled? ? Output.new(io, self) : io

    def start(verb, total)
      @verb = verb
      @total = total
      @done = 0
      @label = ""
    end

    # Names an item being worked on. With several in flight, the line shows
    # the one picked up most recently.
    def started(label)
      @label = label
      redraw
    end

    # Counts finished items, so the number only rises and reaches the total
    # exactly when the work is done.
    def finished(done)
      @done = done
      redraw
    end

    # Clears the line for good.
    def finish
      return unless enabled? && @line

      @io.write(CLEAR)
      @line = nil
    end

    def around
      return yield unless enabled? && @line

      @io.write(CLEAR)
      result = yield
      draw
      result
    end

    private

    def redraw
      return unless enabled?

      @line = fit("#{@verb} #{@done}/#{@total}  #{@label}")
      draw
    end

    def draw
      @io.write("#{CLEAR}#{@line}")
      @io.flush
    end

    # A line wider than the terminal wraps, and a wrapped line cannot be
    # rewritten in place.
    def fit(text)
      width = (@io.winsize[1] if @io.respond_to?(:winsize)).to_i
      width = DEFAULT_WIDTH unless width > 10
      text.length < width ? text : "#{text[0, width - 4]}..."
    rescue SystemCallError, IOError
      text[0, DEFAULT_WIDTH - 1]
    end
  end
end
