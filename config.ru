$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'argentum'

Argentum.boot!
run Argentum::App
