# frozen_string_literal: true

require_relative "flexr/runtime"

module Flexr
  autoload :ArtifactWriter, File.expand_path("flexr/artifact_writer", __dir__)
  autoload :Codegen, File.expand_path("flexr/codegen", __dir__)
  autoload :Source, File.expand_path("flexr/source", __dir__)
  autoload :Generator, File.expand_path("flexr/generator", __dir__)
  autoload :Importer, File.expand_path("flexr/importer", __dir__)
  autoload :Options, File.expand_path("flexr/options", __dir__)
  autoload :RakeTask, File.expand_path("flexr/rake_task", __dir__)
  autoload :CLI, File.expand_path("flexr/cli", __dir__)
end
