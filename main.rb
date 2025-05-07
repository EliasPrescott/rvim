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
    as_i = Integer(input, exception: false)
    if as_i
      @state.goto_line as_i
    else
      binding.eval input
    end
  end

  def q
    @state.should_quit = true
  end

  def e(path = nil)
    if path
      @state.open_buffer path
    else
      raise "Cannot reopen buffer that is not backed by a file" unless @state.current_buffer.backing_file_path
      @state.current_buffer.load_backing_file
    end
  end

  def w
    @state.save_buffer
  end

  def wq
    @state.save_buffer
    @state.should_quit = true
  end

  def dbg
    @state.dbg
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
  end
end

class RVimBuffer
  attr_accessor :backing_file_path
  attr_accessor :lines
  attr_accessor :read_only
  attr_accessor :cursor
  attr_accessor :line_count
  attr_accessor :starting_row
  attr_accessor :enter_action
  attr_accessor :is_directory

  def initialize path
    @cursor = [0, 0]
    @backing_file_path = path
    @read_only = true
    @lines = []
    @starting_row = 0
    @is_directory = false
    if @backing_file_path
      load_backing_file
    end
  end

  def load_backing_file
    @backing_file_path = File.expand_path @backing_file_path
    if Dir.exist? @backing_file_path
      @is_directory = true
      @lines = Dir.children @backing_file_path
      @lines.sort!
      @enter_action = ->(state) {
        state.open_buffer File.join(@backing_file_path, current_line) if current_line
      }
      return
    end
    File.open @backing_file_path, 'w' unless File.exist? @backing_file_path
    @lines = File.read(@backing_file_path).lines.map {|x| x.chomp}
    @read_only = false
  end

  def insert char, pos
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

  def perform_enter_action state
    @enter_action.call state if @enter_action
  end
end

def blank_buffer
  RVimBuffer.new nil
end

l = Logger.new('test.log')

NORMAL_KEYMAPS = {
  'j' => ->(s, n) { s.cursor = [s.cursor[0] + n, s.cursor[1]] },
  'k' => ->(s, n) { s.cursor = [s.cursor[0] - n, s.cursor[1]] },
  'h' => ->(s, n) { s.cursor = [s.cursor[0], s.cursor[1] - n] },
  'l' => ->(s, n) { s.cursor = [s.cursor[0], s.cursor[1] + n] },
  '0' => ->(s, _n) {
    s.cursor = [s.cursor[0], 0]
  },
  '$' => ->(s, _n) {
    s.cursor = [s.cursor[0], s.get_buffer_winsize[1]]
  },
  'gg' => ->(s, _n) { s.cursor = [0, s.cursor[1]] },
  'G' => ->(s, _n) { s.cursor = [s.current_buffer.lines.length - 1, s.cursor[1]] },
  'i' => ->(s, _n) { s.mode = :insert },
  'a' => ->(s, _n) {
    s.cursor = [s.cursor.row, s.cursor.col + 1]
    s.mode = :insert
  },
  'o' => ->(s, _n) {
    current_line = s.current_buffer.nth_line s.cursor.row
    space_match = current_line.match(/\A +/)
    space_count = 0
    space_count = space_match[0].length if space_match
    s.current_buffer.lines.insert (s.cursor.row + 1), " " * space_count
    s.cursor = [s.cursor.row + 1, space_count]
    s.mode = :insert
  },
  'O' => ->(s, _n) {
    current_line = s.current_buffer.nth_line s.cursor.row
    space_match = current_line.match(/\A +/)
    space_count = 0
    space_count = space_match[0].length if space_match
    s.current_buffer.lines.insert s.cursor.row, " " * space_count
    s.cursor = [s.cursor.row, space_count]
    s.mode = :insert
  },
  'zz' => ->(s, _n) { s.center_buffer_around_cursor },
  'dd' => ->(s, _n) {
    s.current_buffer.lines.slice! s.cursor.row
  },
  ?\C-d => ->(s, _n) {
    move_amount = s.get_buffer_winsize.row / 2
    s.current_buffer.starting_row += move_amount
    s.cursor = [s.cursor.row + move_amount, s.cursor.col]
  },
  ?\C-u => ->(s, _n) {
    move_amount = s.get_buffer_winsize.row / 2
    s.current_buffer.starting_row -= move_amount
    s.cursor = [s.cursor.row - move_amount, s.cursor.col]
  },
  ?\C-f => ->(s, _n) {
    move_amount = s.get_buffer_winsize.row
    s.current_buffer.starting_row += move_amount
    s.cursor = [s.cursor.row + move_amount, s.cursor.col]
  },
  ?\C-b => ->(s, _n) {
    move_amount = s.get_buffer_winsize.row
    s.current_buffer.starting_row -= move_amount
    s.cursor = [s.cursor.row - move_amount, s.cursor.col]
  },
  ?\r => -> (s, _n) { s.current_buffer.perform_enter_action s },
  ?\n => -> (s, _n) { s.current_buffer.perform_enter_action s },
  '-' => -> (s, _n) {
    return unless s.current_buffer.backing_file_path
    current_path = Pathname.new(File.expand_path(s.current_buffer.backing_file_path))
    s.open_buffer current_path.parent.to_s
  }
}

class RVimState
  attr_accessor :mode
  attr_accessor :console
  attr_accessor :logger
  attr_accessor :buffers
  attr_accessor :current_buffer
  attr_accessor :command_center
  attr_accessor :should_quit
  attr_accessor :yank_register
  attr_accessor :drawings

  def initialize console, logger
    @drawings = []
    @mode = :normal
    @console = console
    @logger = logger
    @current_buffer = blank_buffer
    @buffers = [@current_buffer]
    @key_stack = []
    @command_input = ""
    @command_center = RVimCommandCenter.new self
    @should_quit = false
    @yank_register = nil
  end

  def dbg
    @console.cooked {
      binding.irb
    }
  end

  def get_buffer_winsize
    size = @console.winsize
    left_margin = 2
    left_margin = @current_buffer.line_count.to_s.length + 1 if @current_buffer
    [size[0] - 2, size[1] - left_margin]
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
        self.cursor = @current_buffer.backspace cursor
        return
      end
      self.cursor = @current_buffer.insert char, cursor
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
    mapping = NORMAL_KEYMAPS[key_seq.join]

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

  def render
    @console.clear_screen

    console_size = @console.winsize

    buf_display_size = get_buffer_winsize
    lines = @current_buffer&.lines || []
    left_margin_length = 2
    left_margin_length = lines.length.to_s.length + 1 if lines != []
    i = 0
    while i < buf_display_size[0]
      line_index = i + @current_buffer.starting_row
      line = lines[line_index]
      if !line
        @console.cursor = [i, 0]
        @console.write "~ ".colorize(:grey)
        i += 1
        next
      end
      left_margin_text = line_index.to_s.rjust(left_margin_length - 1, " ").colorize(:grey)
      @console.cursor = [i, 0]
      @console.write "#{left_margin_text} #{line[0..buf_display_size[1]]}"
      i += 1
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
    current_buffer_display = @current_buffer.backing_file_path ?
      @current_buffer.backing_file_path :
      "scratch buffer"
    @console.write "#{color_status_bar(" #{@mode.to_s.upcase!} ")} #{current_buffer_display}"

    right_statusline_info = "#{@current_buffer.cursor}"
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

    @console.cursor = [cursor.row - @current_buffer.starting_row, cursor.col + left_margin_length]
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
    @current_buffer = RVimBuffer.new path
    @buffers << @current_buffer
  end

  def save_buffer
    raise "Cannot save a readonly buffer" if @current_buffer.read_only
    raise "Cannot save a buffer without a file path" unless @current_buffer.backing_file_path
    raise "Cannot (currently) save changes to a directory buffer" if @current_buffer.is_directory
    File.write @current_buffer.backing_file_path, @current_buffer.lines.join("\n")
  end

  def color_status_bar text
    text.colorize(:color => :black, :background => MODE_COLORS[@mode], :mode => :bold)
  end

  def cursor 
    @current_buffer&.cursor
  end

  def constrain_cursor_pos pos
    new_row = pos[0].clamp(0, @current_buffer.line_count)
    [
      # eventually will constrain to be <= the longest/current line length
      new_row,
      pos[1].clamp(0, @current_buffer.nth_line(new_row)&.length || 0),
    ]
  end

  def cursor= position
    @current_buffer.cursor = constrain_cursor_pos(position) if @current_buffer
    scroll_current_buffer_to_contain_cursor
  end

  def scroll_current_buffer_to_contain_cursor
    display_size = get_buffer_winsize
    view_start = @current_buffer.starting_row
    view_end = @current_buffer.starting_row + display_size[0]
    if @current_buffer.cursor.row > view_end
      @current_buffer.starting_row += @current_buffer.cursor.row - view_end
    end
    if @current_buffer.cursor.row < view_start
      @current_buffer.starting_row = @current_buffer.cursor.row
    end
  end

  def goto_line line_num
    self.cursor = [line_num, cursor.col] if cursor
  end

  def center_buffer_around_cursor
    return if !@current_buffer
    display_size = get_buffer_winsize
    @current_buffer.starting_row = cursor.row - display_size.x / 2
  end
end

c = IO.console
s = RVimState.new c, l

c.raw!
c.clear_screen

if ARGV.first
  s.open_buffer ARGV.first
end

s.render

while !s.should_quit do
  # roughly aiming for 60 FPS
  sleep 0.016
  byte_count = c.nread
  if byte_count > 0
    byte = c.readbyte
    char = [byte].pack("C*")
    s.send_input char

    s.render
  end
end

c.clear_screen
c.cooked!
