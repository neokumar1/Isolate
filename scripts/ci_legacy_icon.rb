#!/usr/bin/env ruby
# The macOS 15 hosted image's Xcode 26.3 asset agent crashes while compiling
# Icon Composer packages. Test that OS with the committed compatibility ICNS;
# newer CI and release builds continue compiling the layered icon.
require 'yaml'

source = YAML.load_file('project.yml')
app = source.fetch('targets').fetch('Isolate')
sources = app.fetch('sources')
unless sources.length == 2 && sources[0]['path'] == 'Sources' &&
       sources[1]['path'] == 'Sources/Resources/AppIcon.icon'
  abort 'Unexpected app icon source layout in project.yml'
end

sources[0]['excludes'] = ['Resources/AppIcon.icon']
sources.pop
app.fetch('settings').fetch('base').delete('ASSETCATALOG_COMPILER_APPICON_NAME')
File.write('project.ci-legacy.yml', YAML.dump(source))
