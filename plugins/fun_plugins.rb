class SmilePlugin < Plugin
  # def on_debug_render _delta
  #   size = state.console.winsize
  #   state.console.cursor = [size.row / 2, size.col / 2 - 2]
  #   state.console.write ":)".colorize(:color => :red)
  # end
end

class FPSPlugin < Plugin
  attr_accessor :elapsed
  attr_accessor :fps
  attr_accessor :display_fps

  def on_startup
    @elapsed = 0
    @fps = 0
  end

  def on_debug_render delta
    @elapsed += delta
    @fps += 1
    if elapsed > 1
      @display_fps = fps
      @fps = 0
      @elapsed = 0
    end

    size = state.console.winsize
    display = " FPS: #{@display_fps} "
    state.console.cursor = [0, size.col - display.length]
    state.console.write display.colorize(:background => :red, :color => :black)
  end
end

class PetsPlugin < Plugin
  attr_accessor :pets

  def on_startup
    @pets = []
    add_pet
  end

  def add_pet
    size = state.console.winsize
    possible_pets = %w(🐢 🐈 🐕 🐍)
    @pets << {:icon => possible_pets.sample, :location => size.col / 2}
  end

  def on_debug_render delta
    size = state.console.winsize
    for pet in @pets
      if rand(0..(1000 * delta).to_i) == 0
        move = rand(-1..1)
        pet[:location] = (pet[:location] + move).clamp(size.col / 4, size.col - 1)
      end
      pos = [size.row, pet[:location]]
      state.console.cursor = pos
      state.console.write pet[:icon]
    end
  end
end