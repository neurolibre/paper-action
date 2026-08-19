#!/usr/bin/env ruby
# Check myst_fallback.rb against inara's myst-frontmatter.lua fixtures.
#
# The Ruby fallback in this repository and the Lua filter in neurolibre/inara
# resolve the same myst.yml into the same metadata; a disagreement silently
# credits the wrong institutions. This replays inara's fixture corpus through
# the Ruby side and compares it with the expected.txt those fixtures pin.
#
# Usage: ruby test/parity.rb /path/to/inara/test/myst-frontmatter/fixtures
#
# The expected.txt files are produced after normalize-metadata.lua has also run,
# so the `cor=` and `eq=` columns it synthesizes are not compared here -- only
# the fields myst-frontmatter.lua itself is responsible for.

require "yaml"
require_relative "../myst_fallback"

fixtures = ARGV[0] || File.expand_path("../../inara/test/myst-frontmatter/fixtures", __dir__)
abort "no fixture directory at #{fixtures}" unless Dir.exist?(fixtures)

def render(metadata)
  authors = Array(metadata["authors"]).map do |a|
    a = { "name" => a.to_s } unless a.is_a?(Hash)
    affs = a["affiliation"].to_s.split(",").map { |i| "<#{i.strip}>" }.join
    "[#{a['name']}|aff=#{affs}|orcid=#{a['orcid']}]"
  end.join
  affiliations = Array(metadata["affiliations"]).map do |a|
    "[#{a['index']}|#{a['name']}]"
  end.join
  [
    "TITLE:#{Array(metadata['title']).join}",
    "DATE:#{metadata['date']}",
    "TAGS:#{Array(metadata['tags']).map { |t| "[#{t}]" }.join}",
    "BIB:#{Array(metadata['bibliography']).map { |b| "[#{b}]" }.join}",
    "AUTHORS:#{authors}",
    "AFFS:#{affiliations}",
  ].join("\n")
end

# Drop the columns normalize-metadata.lua owns, so the two sides are comparable.
def reduce_expected(text)
  text.lines.filter_map do |line|
    next if line.start_with?("CORRESP:")
    line = line.gsub(/\|cor=[^|\]]*\|eq=[^|\]]*/, "")
    # normalize-metadata.lua gives an author with no affiliation an empty
    # `affiliation`, which the template renders as one empty iteration. The
    # filter itself emits no key at all, which is what the Ruby side mirrors.
    line = line.gsub("|aff=<>|", "|aff=|")
    line.chomp
  end.join("\n")
end

failures = []
Dir.children(fixtures).sort.each do |name|
  dir = File.join(fixtures, name)
  paper = File.join(dir, "paper.md")
  next unless File.file?(paper)

  metadata = begin
    YAML.load_file(paper)
  rescue Psych::Exception
    {}
  end
  actual = render(MystFallback.apply(metadata, paper, dir))
  expected = reduce_expected(File.read(File.join(dir, "expected.txt")))

  if actual == expected
    puts "ok   #{name}"
  else
    puts "FAIL #{name}"
    puts expected.lines.zip(actual.lines).reject { |e, a| e == a }
                 .map { |e, a| "       lua: #{e.to_s.chomp}\n      ruby: #{a.to_s.chomp}" }
    failures << name
  end
end

puts
if failures.empty?
  puts "all fixtures agree"
else
  puts "#{failures.length} disagreement(s): #{failures.join(', ')}"
  exit 1
end
