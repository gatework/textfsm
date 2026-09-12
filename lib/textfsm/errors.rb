# frozen_string_literal: true

module TextFSM
  class Error < StandardError; end
  class TemplateError < Error; end
  class ParseError < Error; end
  class IndexError < Error; end
end
