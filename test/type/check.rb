# frozen_string_literal: true

# RBS is development-only. The installed smoke runs against released runtime gems.
require "rbs"
require "rbs/test"
require "stringio"
require "pathname"
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "canopus"
require "canopus/lazy_rope"
require "canopus/performance_recorder"
require "canopus/workspace/edit/plan"
require "canopus/cli"
require "canopus/markdown"
require "canopus/icon_theme"

RBS.logger_level = :error
root = File.expand_path("../..", __dir__)
loader = RBS::EnvironmentLoader.new
loader.add(library: "strscan")
%w[alhena antares denebola zaniah].each { |library| loader.add(library: library) }
loader.add(path: Pathname(File.join(root, "sig")))
environment = RBS::Environment.from_loader(loader).resolve_type_names
tester = RBS::Test::Tester.new(env: environment)
# Git::ObjectDatabase.hash computes Git object IDs and intentionally requires arguments.
# Identity keys keep the checker from invoking domain-level .hash methods.
tester.instance_testers.compare_by_identity
tester.singleton_testers.compare_by_identity
checked = 0
environment.class_decls.each_key do |name|
  next unless name.to_s.start_with?("::Canopus")
  target = name.to_s.delete_prefix("::").split("::").reduce(Object) do |parent, part|
    break nil unless parent.const_defined?(part, false)
    parent.const_get(part, false)
  end
  raise "signature without loaded class: #{name}" unless target.is_a?(Module)
  instance = tester.builder.build_instance(name)
  singleton = tester.builder.build_singleton(name)
  instance.methods.each do |method_name, definition|
    next unless definition.implemented_in == name
    next if method_name == :initialize
    raise "signature without implementation: #{name}##{method_name}" unless target.method_defined?(method_name) || target.private_method_defined?(method_name)
    checked += 1
  end
  singleton.methods.each do |method_name, definition|
    next unless definition.implemented_in == name
    raise "signature without implementation: #{name}.#{method_name}" unless target.respond_to?(method_name, true)
    checked += 1
  end
  # Both directions for every declared application class. Generated Struct/Data
  # factory/inspection methods are inherited from core RBS, not redefined.
  missing = target.public_instance_methods(false) - instance.methods.keys
  missing_singleton = target.singleton_methods(false).reject do |method_name|
    singleton.methods.key?(method_name) || target.method(method_name).source_location.nil?
  end
  raise "public implementation without signature: #{name}: #{missing + missing_singleton}" unless missing.empty? && missing_singleton.empty?
  tester.install!(target, sample_size: 10, unchecked_classes: [])
end
raise "incomplete public API checks" if checked < 300
require_relative "smoke"
begin
  Canopus::Terminal::Grid.new(columns: "wide")
  raise "runtime type checker failed to reject an invalid column count"
rescue RBS::Test::Tester::TypeError
  # The negative control proves that argument validation hooks really ran.
end
puts "RBS runtime conformance: #{checked} public members checked across #{tester.targets.length} loaded classes/modules"
