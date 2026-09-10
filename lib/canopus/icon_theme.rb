# frozen_string_literal: true

module Canopus
  # Theme JSON maps file/directory/expanded_directory and extensions to local SVGs.
  class IconTheme
    FILE = '<svg viewBox="0 0 16 16"><path d="M3 1h6l4 4v10H3z M9 1v4h4" fill="none" stroke="currentColor" stroke-linejoin="round"/></svg>'
    FOLDER = '<svg viewBox="0 0 16 16"><path d="M1 4V2h5l2 2h7v10H1z" fill="none" stroke="currentColor" stroke-linejoin="round"/></svg>'
    def initialize(path = nil)
      @icons, @extensions = {}, {}
      if path
        raise Error, "icon theme exceeds 256 KiB" if File.size(path) > 262_144
        document = Kochab.parse(File.read(path))
        raise Error, "invalid icon theme" unless document.valid? && document.value.is_a?(Hash)
        @root, @definition = File.realpath(File.dirname(path)), document.value
        @extensions = @definition.fetch("extensions", {})
        raise Error, "icon extensions must be a map with at most 256 entries" unless @extensions.is_a?(Hash) && @extensions.length <= 256
        paths = @definition.values_at("file", "directory", "expanded_directory").compact + @extensions.values
        paths.uniq.each { |value| load_icon(value) }
      else
        @definition = {}
      end
      @icons[:file] = Zaniah::SVG.new(FILE)
      @icons[:directory] = Zaniah::SVG.new(FOLDER)
    end
    def texture(path, directory: false, expanded: false, size: 16, scale: 1, color: "#999")
      key = if directory
        @definition[expanded ? "expanded_directory" : "directory"] || @definition["directory"] || :directory
      else
        @extensions[File.extname(path)] || @extensions[File.basename(path)] || @definition["file"] || :file
      end
      pixels = (size * scale).ceil
      @icons.fetch(key).texture(width: pixels, height: pixels, color: color)
    end
    private
    def load_icon(relative)
      raise Error, "icon filename must be a string" unless relative.is_a?(String)
      full = File.realpath(File.expand_path(relative, @root))
      raise Error, "icon must remain inside the theme directory" unless full.start_with?(@root + File::SEPARATOR)
      raise Error, "icon exceeds 2 MiB" if File.size(full) > 2_097_152
      @icons[relative] = Zaniah::SVG.open(full)
    end
  end
end
