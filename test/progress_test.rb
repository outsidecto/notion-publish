# frozen_string_literal: true

require "test_helper"

class ProgressTest < Minitest::Test
  def terminal(width: 60)
    StringIO.new.tap do |io|
      io.define_singleton_method(:tty?) { true }
      io.define_singleton_method(:winsize) { [24, width] }
    end
  end

  def test_each_step_rewrites_one_line
    io = terminal
    progress = NotionPublish::Progress.new(io, enabled: true)
    progress.start("Checking", 2)
    progress.step("a.md")
    progress.step("b.md")

    assert_equal "\r\e[KChecking 1/2  a.md\r\e[KChecking 2/2  b.md", io.string
  end

  def test_finish_leaves_the_line_empty
    io = terminal
    progress = NotionPublish::Progress.new(io, enabled: true)
    progress.start("Checking", 1)
    progress.step("a.md")
    progress.finish

    assert io.string.end_with?("\r\e[K")
  end

  def test_output_clears_the_line_first_and_redraws_it_after
    io = terminal
    progress = NotionPublish::Progress.new(io, enabled: true)
    out = progress.wrap(io)
    progress.start("Checking", 1)
    progress.step("a.md")
    io.truncate(0)
    io.rewind

    out.puts "Updated a.md"

    assert_equal "\r\e[KUpdated a.md\n\r\e[KChecking 1/1  a.md", io.string
  end

  def test_a_long_name_is_cut_to_the_terminal_width
    io = terminal(width: 30)
    progress = NotionPublish::Progress.new(io, enabled: true)
    progress.start("Checking", 1)
    progress.step("a-very-long-file-name-that-would-wrap.md")

    line = io.string.delete_prefix("\r\e[K")

    assert_operator line.length, :<, 30
    assert line.end_with?("...")
  end

  def test_disabled_progress_writes_nothing_and_wraps_nothing
    io = StringIO.new
    progress = NotionPublish::Progress.new(io, enabled: false)
    progress.start("Checking", 1)
    progress.step("a.md")
    progress.finish

    assert_equal "", io.string
    assert_same io, progress.wrap(io)
  end
end
