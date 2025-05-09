require 'pp'
require 'irb'
require 'logger'
require 'io/console'
require 'io/wait'
require 'colorize'
require 'pathname'

DRAWING_COLORS = [
  :blue,
  :green,
  :yellow,
  :red,
]

module Drawings
  RVIM = [
    "▗▄▄▖ ▗▖  ▗▖▗▄▄▄▖▗▖  ▗▖",
    "▐▌ ▐▌▐▌  ▐▌  █  ▐▛▚▞▜▌",
    "▐▛▀▚▖▐▌  ▐▌  █  ▐▌  ▐▌",
    "▐▌ ▐▌ ▝▚▞▘ ▗▄█▄▖▐▌  ▐▌",
  ]

  CIRCLE = [
    "      ██████████      ",
    "   ████████████████   ",
    " ████████████████████ ",
    "██████████████████████",
    "██████████████████████",
    "██████████████████████",
    "██████████████████████",
    "██████████████████████",
    " ████████████████████ ",
    "   ████████████████   ",
    "      ██████████      ",
  ]
end

MODE_COLORS = {
  :normal => :yellow,
  :insert => :green,
  :command => :red,
}

class Array
  def row
    self[0]
  end

  def col
    self[1]
  end

  def x
    self[0]
  end

  def y
    self[1]
  end
end

class RVimDrawing
  attr_accessor :pos
  attr_accessor :left
  attr_accessor :right
  attr_accessor :top
  attr_accessor :bottom
  attr_accessor :drawing
  attr_accessor :color
end

class RVimCommandCenter
  attr_accessor :state

  def initialize state
    @state = state
  end

  def eval input
    @state.logger.info "Evaluating command: #{input.inspect}"
    as_i = Integer(input, exception: false)
    if as_i
      @state.goto_line as_i
    else
      begin
        result = binding.eval input

        if result
          win = _show "command results", result.pretty_inspect
          cmd = input.clone
          # utility mapping to refresh the show output buffer
          win.buffer.keymappings['r'] = ->(s, _n) do
            @state.close_current_window
            eval cmd
          end
        end
      rescue Exception => e
        _show e.class.to_s, e.message
      end
    end
  end

  def q
    @state.quit
    nil
  end

  def e(path = nil)
    if path
      buf = @state.open_buffer path
      @state.current_window.buffer = buf
    else
      raise "Cannot reopen buffer that is not backed by a file" unless @state.current_window.buffer.backing_file_path
      @state.current_window.buffer.load_backing_file
    end
    nil
  end

  def w
    @state.save_buffer
    nil
  end

  def wq
    @state.save_buffer
    @state.should_quit = true
    nil
  end

  def dbg
    @state.dbg
    nil
  end

  def _show name, msg
    size = @state.console.winsize
    buf = RVimBuffer.create_from_text msg
    buf.name = name
    buf.keymappings['q'] = ->(s, _n) { @state.close_current_window }
    @state.buffers << buf
    extra_offset = @state.floating_window_count * 2
    pos = [size.row / 4 + extra_offset, size.col / 4 + extra_offset]
    win_size = [size.row / 2, size.col / 2]
    win = @state.create_popup_window buf, pos, win_size
    @state.windows << win
    @state.current_window = win
    win
  end

  def fun
    if @state.drawings.any?
      @state.drawings = []
      return
    end

    rvim = RVimDrawing.new
    rvim.drawing = Drawings::RVIM
    rvim.right = 0
    rvim.top = 0
    rvim.color = :blue
    @state.drawings << rvim

    circle = RVimDrawing.new
    circle.drawing = Drawings::CIRCLE
    circle.right = 0
    circle.bottom = 3
    circle.color = :red
    @state.drawings << circle

    "Have fun!"
  end
end

class RVimWindow
  attr_accessor :start_pos
  attr_accessor :size
  attr_accessor :active
  attr_accessor :buffer
  attr_accessor :is_floating
end

class RVimBuffer
  attr_accessor :name
  attr_accessor :backing_file_path
  attr_accessor :lines
  attr_accessor :read_only
  attr_accessor :cursor
  attr_accessor :line_count
  attr_accessor :starting_row
  attr_accessor :is_directory
  attr_accessor :keymappings

  def initialize path
    @name = "blank buffer"
    @cursor = [0, 0]
    @backing_file_path = path
    @read_only = true
    @lines = []
    @starting_row = 0
    @is_directory = false
    @keymappings = {}
    if @backing_file_path
      @name = @backing_file_path
      load_backing_file
    end
  end

  def self.create_from_text text
    b = RVimBuffer.new nil
    b.lines = text.lines.map {|x| x.chomp}
    b
  end

  def load_backing_file
    if Dir.exist? @backing_file_path
      @is_directory = true
      @lines = Dir.children @backing_file_path
      @lines.sort!
      @keymappings[?\r] = @keymappings[?\n] = ->(state, _n) {
        buf = state.open_buffer File.join(@backing_file_path, current_line) if current_line
        state.current_window.buffer = buf
      }
      return
    end
    File.open @backing_file_path, 'w' unless File.exist? @backing_file_path
    @lines = File.read(@backing_file_path).lines.map {|x| x.chomp}
    @read_only = false
  end

  def insert char, pos
    @lines = [""] if lines == [] or lines == nil
    return pos if pos.row < 0
    return pos if pos.row > lines.length
    return pos if pos.col < 0
    line = nth_line(pos.row)
    return pos if pos.col > line.length

    if char == ?\n or char == ?\r
      rhs = line.slice!(pos.col..)
      lines.insert pos.row + 1, rhs
      return [pos.row + 1, 0]
    end

    line.insert pos.col, char

    return [pos.row, pos.col + 1]
  end

  def backspace pos
    if pos.col == 0
      pos = [pos.row - 1, nth_line(pos.row - 1).length]
      lines.slice! pos.row + 1
      return pos
    end

    return pos if pos.row < 0
    return pos if pos.row > lines.length
    return pos if pos.col < 0
    line = nth_line(pos.row)
    return pos if pos.col > line.length

    line.slice! (pos.col - 1)

    return [pos.row, pos.col - 1]
  end

  def current_line
    lines[@cursor.row]
  end

  def nth_line n
    lines[n]
  end
end

def blank_buffer
  RVimBuffer.new nil
end

l = Logger.new('test.log')

NORMAL_KEYMAPS = {
  'j' => ->(s, n) { s.cursor = [s.cursor.row + n, s.cursor.col] },
  'k' => ->(s, n) { s.cursor = [s.cursor[0] - n, s.cursor[1]] },
  'h' => ->(s, n) { s.cursor = [s.cursor[0], s.cursor[1] - n] },
  'l' => ->(s, n) { s.cursor = [s.cursor[0], s.cursor[1] + n] },
  '0' => ->(s, _n) {
    s.cursor = [s.cursor[0], 0]
  },
  '$' => ->(s, _n) {
    s.cursor = [s.cursor[0], s.current_window.size.col]
  },
  'gg' => ->(s, _n) { s.cursor = [0, s.cursor[1]] },
  'G' => ->(s, _n) { s.cursor = [s.current_window.buffer.lines.length - 1, s.cursor[1]] },
  'i' => ->(s, _n) { s.mode = :insert },
  'a' => ->(s, _n) {
    s.cursor = [s.cursor.row, s.cursor.col + 1]
    s.mode = :insert
  },
  'o' => ->(s, _n) {
    current_line = s.current_window.buffer.nth_line s.cursor.row
    space_match = current_line.match(/\A +/)
    space_count = 0
    space_count = space_match[0].length if space_match
    s.current_window.buffer.lines.insert (s.cursor.row + 1), " " * space_count
    s.cursor = [s.cursor.row + 1, space_count]
    s.mode = :insert
  },
  'O' => ->(s, _n) {
    current_line = s.current_window.buffer.nth_line s.cursor.row
    space_match = current_line.match(/\A +/)
    space_count = 0
    space_count = space_match[0].length if space_match
    s.current_window.buffer.lines.insert s.cursor.row, " " * space_count
    s.cursor = [s.cursor.row, space_count]
    s.mode = :insert
  },
  'zz' => ->(s, _n) { s.center_buffer_around_cursor s.current_window },
  'dd' => ->(s, _n) {
    s.current_window.buffer.lines.slice! s.cursor.row
  },
  ?\C-d => ->(s, _n) {
    move_amount = s.current_window.size.row / 2
    s.current_window.buffer.starting_row += move_amount
    s.cursor = [s.cursor.row + move_amount, s.cursor.col]
  },
  ?\C-u => ->(s, _n) {
    move_amount = s.current_window.size.row / 2
    s.current_window.buffer.starting_row -= move_amount
    s.cursor = [s.cursor.row - move_amount, s.cursor.col]
  },
  ?\C-f => ->(s, _n) {
    move_amount = s.current_window.size.row
    s.current_window.buffer.starting_row += move_amount
    s.cursor = [s.cursor.row + move_amount, s.cursor.col]
  },
  ?\C-b => ->(s, _n) {
    move_amount = s.current_window.size.row
    s.current_window.buffer.starting_row -= move_amount
    s.cursor = [s.cursor.row - move_amount, s.cursor.col]
  },
  '-' => -> (s, _n) {
    return unless s.current_window.buffer.backing_file_path
    current_path = Pathname.new(File.expand_path(s.current_window.buffer.backing_file_path))
    buf = s.open_buffer current_path.parent.to_s
    s.current_window.buffer = buf
  }
}

class RVimState
  attr_accessor :target_fps
  attr_accessor :mode
  attr_accessor :console
  attr_accessor :logger
  attr_accessor :buffers
  attr_accessor :command_center
  attr_accessor :should_quit
  attr_accessor :yank_register
  attr_accessor :drawings
  attr_accessor :plugins
  attr_accessor :command_input
  attr_accessor :windows

  def initialize console, logger
    logger.info "initializing state"
    @target_fps = 120
    @plugins = {}
    @drawings = []
    @mode = :normal
    @console = console
    @logger = logger

    start_buffer = blank_buffer
    start_window = create_main_window start_buffer

    @buffers = [start_buffer]
    @windows = [start_window]
    @key_stack = []
    @command_input = ""
    @command_center = RVimCommandCenter.new self
    @should_quit = false
    @yank_register = nil
  end

  def current_window
    @windows.find {|x| x.active}
  end

  def current_window= window
    raise "Cannot mark an unregistered window as active" unless @windows.include? window
    @windows.each {|x| x.active = false}
    window.active = true
  end

  def create_main_window buffer
    w = RVimWindow.new
    w.buffer = buffer

    available_size = @console.winsize
    w.active = true
    w.is_floating = false
    w.start_pos = [0, 0]
    w.size = [available_size.row - 2, available_size.col]
    w
  end

  def create_popup_window buffer, pos, size
    w = RVimWindow.new
    w.buffer = buffer
    w.is_floating = true
    w.start_pos = pos
    w.size = size
    w
  end

  def floating_window_count
    @windows.filter {|x| x.is_floating}.length
  end

  def on_startup
    @plugins.values.filter {|p| p.respond_to? :on_startup}.each {|p| p.on_startup}
  end

  def quit
    if @windows.length > 1
      self.close_current_window
      return
    end

    @should_quit = true
  end

  def close_current_window
    @windows.delete self.current_window
    self.current_window = @windows.last
  end

  def dbg
    @console.clear_screen
    @console.cooked {
      binding.irb
    }
  end

  def send_input char
    case @mode
    when :normal
      # use <esc> to cancel the current key stack
      if char == "\e"
        @key_stack = []
        return
      end
      # goto command mode on :
      case char
      when ':'
        @mode = :command
        return
      end
      @key_stack << char
      try_call_keymapping
    when :insert
      # use <esc> to exit back to normal mode
      case char
      when "\e"
        @mode = :normal
        return
      when "\b", "\c?"
        self.cursor = current_window.buffer.backspace cursor
        return
      end
      self.cursor = current_window.buffer.insert char, cursor
    when :command
      # use <esc> to exit back to normal mode
      case char 
      when "\e"
        @mode = :normal
        @command_input = ""
        return
      when "\r"
        execute_command
        return
      when "\b", "\c?"
        if @command_input.empty?
          @mode = :normal
          return
        end
        @command_input = @command_input[0..-2]
        return
      end
      @command_input << char
    else
      raise "Unknown mode: #{@mode}"
    end
  end

  def try_call_keymapping
    numeric_prefix_seq = @key_stack.take_while {|x| Integer(x, exception: false)}
    if numeric_prefix_seq[0] == '0'
      numeric_prefix_seq = []
    end
    numeric_modifier = Integer(numeric_prefix_seq.join, exception: false) || 1

    key_seq = @key_stack[numeric_prefix_seq.length..]

    buffer_keymappings = current_window.buffer.keymappings
    mapping = buffer_keymappings[key_seq.join]

    mapping = NORMAL_KEYMAPS[key_seq.join] unless mapping

    if mapping
      @key_stack = []
      mapping.call self, numeric_modifier
    else
      # reset the key stack if it has more chars than any known mapping
      @key_stack = [] if NORMAL_KEYMAPS.keys.none? {|key| key.length >= key_seq.length}
    end
  end

  def execute_command
    _res = @command_center.eval @command_input
    @command_input = ""
    @mode = :normal
  end

  # debug_render runs independently of the main render and allows plugins to draw over any element
  def debug_render delta
    @console.syswrite "\x1b7"
    @plugins.values.filter {|p| p.respond_to? :on_debug_render}.map {|p| p.on_debug_render delta}
    @console.syswrite "\x1b8"
  end

  def render
    @console.clear_screen

    console_size = @console.winsize

    for window in @windows
      lines = window.buffer&.lines || []
      left_margin_length = 2
      left_margin_length = lines.length.to_s.length + 1 if lines != []
      floating_offset = window.is_floating ? 1 : 0
      i = 0

      if window.is_floating
        @console.cursor = [window.start_pos.row - 1, window.start_pos.col - floating_offset]
        @console.write "┌#{"─" * (window.size.col + floating_offset)}┐"
      end

      while i < window.size.row
        line_index = i + window.buffer.starting_row
        line = lines[line_index]
        if !line
          @console.cursor = [i + window.start_pos.row, window.start_pos.col - floating_offset]
          @console.write ?│ if window.is_floating
          @console.write "~".ljust(window.size.col + 1, " ").colorize(:grey)
          if window.is_floating
            @console.cursor = [i + window.start_pos.row, window.start_pos.col + window.size.col + floating_offset]
            @console.write ?│
          end
          i += 1
          next
        end

        left_margin_text = line_index.to_s.rjust(left_margin_length - 1, " ").colorize(:grey)
        line_text = line[0..window.size.col - left_margin_length]
        @console.cursor = [i + window.start_pos.row, window.start_pos.col - floating_offset]
        @console.write ?│ if window.is_floating
        @console.write "#{left_margin_text} #{line_text.ljust(window.size.col - left_margin_length + 1, " ")}"
        if window.is_floating
          @console.cursor = [i + window.start_pos.row, window.start_pos.col + window.size.col + floating_offset]
          @console.write ?│
        end
        i += 1
      end

      if window.is_floating
        @console.cursor = [window.start_pos.row + window.size.row, window.start_pos.col - floating_offset]
        @console.write "└#{"─" * (window.size.col + floating_offset)}┘"
      end
    end

    for drawing in @drawings
      drawing_width = drawing.drawing.first.length
      drawing_height = drawing.drawing.length
      row = 0
      if drawing.top
        row = drawing.top
      elsif drawing.bottom
        row = console_size.row - drawing.bottom - drawing_height
      end
      col = 0
      if drawing.left
        col = drawing.left
      elsif drawing.right
        col = console_size.col - drawing.right - drawing_width
      end
      render_drawing [row, col], drawing
    end

    size = @console.winsize
    @console.cursor = [size[0] - 2, 0]
    
    w = current_window

    # write the file path info
    current_window_display = w.buffer.name
    current_window_display += " [readonly]" if w.buffer.read_only
    @console.write "#{color_status_bar(" #{@mode.to_s.upcase!} ")} #{current_window_display}"

    # display the cursor position within the current window
    right_statusline_info = "#{w.buffer.cursor}"
    if @key_stack != []
      right_statusline_info += " #{@key_stack.join}"
    end
    @console.cursor = [size[0] - 2, size[1] - 1 - right_statusline_info.length]
    @console.write color_status_bar(right_statusline_info)

    if @mode == :command
      @console.cursor = [size[0] - 1, 0]
      @console.write ":#{@command_input}"
      return
    end

    c = cursor
    @console.cursor = [cursor.row - w.buffer.starting_row + w.start_pos.row, c.col + left_margin_length + w.start_pos.col] unless @mode == :command
    @console.flush
  end

  def render_drawing pos, drawing
    for row in 0..drawing.drawing.length
      line = drawing.drawing[row]
      next unless line
      i = 0
      for is_whitespace, segment in line.chars.chunk {|x| x == " "} do
        if is_whitespace
          i += segment.length
          next
        end
        @console.cursor = [row + pos.row, pos.col + i]
        @console.write segment.join.colorize(:color => drawing.color)
        i += segment.length
      end
    end
  end

  def open_buffer path
    path = File.expand_path path

    existing_buffer_for_path = @buffers.find {|x| x.backing_file_path == path}
    if existing_buffer_for_path
      return existing_buffer_for_path
    end

    buf = RVimBuffer.new path
    @plugins.values.filter {|p| p.respond_to? :on_buffer_open}.each {|p| p.on_buffer_open buf}
    @buffers << buf
    buf
  end

  def save_buffer
    buf = current_window.buffer
    raise "Cannot save a readonly buffer" if buf.read_only
    raise "Cannot save a buffer without a file path" unless buf.backing_file_path
    raise "Cannot (currently) save changes to a directory buffer" if buf.is_directory
    File.write buf.backing_file_path, buf.lines.join("\n")
  end

  def color_status_bar text
    text.colorize(:color => :black, :background => MODE_COLORS[@mode], :mode => :bold)
  end

  def cursor 
    current_window.buffer.cursor
  end

  def constrain_cursor_pos pos, window
    new_row = pos[0].clamp(0, window.buffer.line_count)
    [
      # eventually will constrain to be <= the longest/current line length
      new_row,
      pos[1].clamp(0, window.buffer.nth_line(new_row)&.length || 0),
    ]
  end

  def cursor= position
    w = current_window
    w.buffer.cursor = constrain_cursor_pos(position, w) if w.buffer
    scroll_window_to_contain_cursor w
  end

  def scroll_window_to_contain_cursor window
    display_size = window.size
    buffer = window.buffer
    view_start = buffer.starting_row
    view_end = buffer.starting_row + display_size[0]
    if buffer.cursor.row > view_end
      buffer.starting_row += buffer.cursor.row - view_end
    end
    if buffer.cursor.row < view_start
      buffer.starting_row = buffer.cursor.row
    end
  end

  def goto_line line_num
    self.cursor = [line_num, cursor.col] if cursor
  end

  def center_buffer_around_cursor window
    return if !window.buffer
    display_size = window.size
    window.buffer.starting_row = window.buffer.cursor.row - display_size.x / 2
  end

  def load_plugins
    Dir["plugins/*.rb", "plugins/*/index.rb"].each do |path|
      @logger.info "Loading plugin from #{path}"
      require_relative path
    end

    Object.constants.each do |klass|
      const = Kernel.const_get(klass)
      if const.respond_to? :superclass and const.superclass == Plugin
        @logger.info "Registering plugin #{klass}"
        p = const.new
        p.state = self
        @plugins[const] = p
      end
    end
  end
end

class Plugin
  attr_accessor :state
end

c = IO.console
s = RVimState.new c, l

s.load_plugins

c.raw!
c.clear_screen

s.on_startup

if ARGV.first
  buf = s.open_buffer ARGV.first
  s.current_window.buffer = buf
end

s.render

last_render_time = Time.now.to_f

while !s.should_quit do
  current_time = Time.now.to_f
  delta = current_time - last_render_time

  byte_count = c.nread
  if byte_count > 0
    byte = c.readbyte
    char = [byte].pack("C*")
    s.send_input char

    # currently only doing a full render on input
    # eventually there should probably be a should_render flag on state to trigger this
    s.render
  end

  s.debug_render delta

  last_render_time = current_time

  sleep (1 / s.target_fps.to_f)
end

c.clear_screen
c.cooked!
