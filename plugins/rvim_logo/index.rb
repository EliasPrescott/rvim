def create_drawing
  d = RVimDrawing.new
  d.drawing = Drawings::RVIM
  d.color = :red
  d.right = 0
  d.bottom = 3
  d
end

class RVimLogoPlugin < Plugin
  def on_startup
    state.drawings << create_drawing
  end
end
